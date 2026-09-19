#!/usr/bin/env bash
# vm.sh — the sandbox. qemu/KVM VM with a virtiofs workspace, bridged net, and
# optionally the physical GPU handed over via VFIO.
#
# This is now the only runtime. Real hardware boundary (KVM + IOMMU); egress
# filtered on iifname virbr-agent by the agent_vm nft table. Run net-up.sh first.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

# Session sizing defaults live in config.sh (VM_MEM/VM_SMP) so you don't have
# to pass them every run; --mem/--smp still override per session.
MEM="$VM_MEM"
SMP="$VM_SMP"
INTERNET_ENABLED=true
HOME_DIR=""
EXTRA_RO=()
EXTRA_RW=()
FROM_NAME=""
TO_NAME=""
SSH_MODE=false
GPU_MODE=false
ACTION=run # run | status | stop
FORCE=false

usage() {
  cat <<EOF
usage: sudo $0 [options]

qemu/KVM VM. The persistent agent home (${MOUNT_HOME}) is mounted over virtiofs
AS the guest's /home/agent, so ~/.claude, ~/.cache/huggingface and every
checkout survive a session. Egress via mitmproxy on ${BRIDGE}.

  --home PATH       host dir to mount as the guest's /home/agent. Defaults to
                    \$MOUNT_HOME from config.sh (set it once in
                    config.local.sh — e.g. to an encrypted key's mountpoint —
                    rather than typing this every run). It must be a dir the
                    agent uid owns: handing the agent a tree YOU own means
                    reviewing-then-running code it wrote, which is the one thing
                    this project is against.
  --gpu             hand the physical GPU to the guest via VFIO. Requires the
                    host to be in sandbox GPU mode first: 'kata gpu-mode
                    sandbox' then reboot. See the note below.
  --ssh             boot headless in the BACKGROUND and ssh into agent@${VM_IP}
                    (far better than the serial console for TUIs/nvim). The
                    guest keeps running when you exit the shell — reconnect
                    with 'kata ssh' from as many terminals as you like, and
                    stop it with 'poweroff' inside or 'kata vm --stop'.
                    Needs the bridge (not compatible with --no-int).
  --no-int          no network attached
  --ro PATH         extra ro mount; tag ro_N, appears at /mnt/ro_N
  --rw PATH         extra rw mount; tag rw_N, appears at /mnt/rw_N
  --mem SIZE        guest memory (default ${VM_MEM}, from config.sh)
  --smp N           guest vCPUs (default ${VM_SMP}, from config.sh)
  --from NAME       boot off the warm base ${VM_BASES_DIR}/NAME.qcow2
                    (default: ${VM_BASE_NAME}, the one 'kata build-base' makes)
  --to NAME         on clean shutdown, flatten this session into a new
                    base ${VM_BASES_DIR}/NAME.qcow2, versioned (v1, v2, …) and
                    tagged with the base it came from. Re-baking an existing
                    name replaces it atomically.
  --force           override a launch guard (CA drift, stale parent). Each one
                    prints what it is protecting you from first; none of them
                    is protecting you from the guest.

  --status          show the running session (no root needed)
  --stop            ACPI-poweroff the running session (clean → --to still bakes)
  --stop --force    SIGTERM qemu instead. Not clean: no bake, no fs sync.

Bases are warm, immutable starting points (e.g. CUDA baked in); each session
still runs on a throwaway overlay, so the running root stays disposable. First
bake (off the blank base): --to cuda (run 'sudo kata-install-cuda' inside, then
poweroff). Then boot warm: --from cuda. Bases hold SYSTEM state only — the home
is a mount, so a login or a downloaded model is never baked into one.
'kata bases' lists them with their version and what they were baked from.

--gpu is all-or-nothing and needs a reboot to switch sides, because the host
cannot release the card while running: systemd-logind holds a DRM fd on it for
seat management, so the only way to free it is to never create the DRM node.
'kata gpu-mode' writes the modprobe/initramfs drop-ins that decide that at boot.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
  --home | --workspace) # --workspace is the old name, kept so muscle memory works
    HOME_DIR="$2"
    shift 2
    ;;
  --status)
    ACTION=status
    shift
    ;;
  --stop)
    ACTION=stop
    shift
    ;;
  --force)
    FORCE=true
    shift
    ;;
  --no-int)
    INTERNET_ENABLED=false
    shift
    ;;
  --ro)
    EXTRA_RO+=("$2")
    shift 2
    ;;
  --rw)
    EXTRA_RW+=("$2")
    shift 2
    ;;
  --mem)
    MEM="$2"
    shift 2
    ;;
  --smp)
    SMP="$2"
    shift 2
    ;;
  --from)
    FROM_NAME="$2"
    shift 2
    ;;
  --to)
    TO_NAME="$2"
    shift 2
    ;;
  --ssh)
    SSH_MODE=true
    shift
    ;;
  --gpu)
    GPU_MODE=true
    shift
    ;;
  -h | --help) usage ;;
  *)
    echo "unknown arg: $1"
    usage
    ;;
  esac
done

# --- Session registry ------------------------------------------------------
# $VM_STATE_FILE is the one place that answers "is a session running, and what
# is it". It was already written for the dashboard; now it also carries the pid
# and the run dir, so `--status`, `--stop`, `kata ssh` and the
# refuse-a-second-session check all read the same file instead of grepping ps.
# World-readable, paths only — `--status` therefore needs no root. The reader
# is state_field() in lib.sh; it used to be defined here AND in kata, and the
# copies diverged (see the comment there).

# Drop a leftover state file + its run dir. Only ever called when the pid is
# confirmed dead, and only as root (it lives under /run).
clear_stale_session() {
  local rd
  rd="$(state_field rundir)"
  [[ $EUID -eq 0 ]] || return 0
  rm -f "$VM_STATE_FILE"
  [[ -n "$rd" && "$rd" == "${VM_RUN_ROOT}/"* ]] && rm -rf "$rd"
  return 0
}

cmd_status() {
  if ! session_alive; then
    if [[ -e "$VM_STATE_FILE" ]]; then
      echo "no session running (stale state file from a killed session)"
      clear_stale_session
    else
      echo "no session running"
    fi
    return 0
  fi
  # Everything below comes from the state file, not from this invocation's flags.
  # That used to matter a great deal: a session's storage MODE was fixed at launch,
  # so `kata vm --status` without --usb reported that a --usb session would bake
  # into /var/lib/agent-vm/bases. With one home and one bases dir there is nothing
  # left to re-resolve — but keep believing the session over the flags, since the
  # home it was launched with can still have been an explicit --home.
  local pid base gpu home mem smp to sess
  pid="$(state_field pid)"
  base="$(state_field base)"
  gpu="$(state_field gpu)"
  home="$(state_field home)"
  mem="$(state_field mem)"
  smp="$(state_field smp)"
  to="$(state_field to)"
  sess="$(state_field session)"
  cat <<EOF
session ${sess} running (qemu pid ${pid})
    base=${base}  gpu=${gpu}  mem=${mem}  smp=${smp}
    home=${home} → /home/${AGENT_USER}${to:+
    will bake → ${VM_BASES_DIR}/${to}.qcow2 on clean poweroff}
    serial log → $(state_field rundir)/serial.log

  connect:  kata ssh
  stop:     kata vm --stop     (or 'poweroff' inside the guest)
EOF
  return 0
}

cmd_stop() {
  [[ $EUID -eq 0 ]] || {
    echo "run as root (kata vm --stop wraps this in sudo)"
    exit 1
  }
  session_alive || {
    echo "no session running"
    if [[ -e "$VM_STATE_FILE" ]]; then clear_stale_session; fi
    exit 0
  }
  local pid rd
  pid="$(state_field pid)"
  rd="$(state_field rundir)"

  # An attached session is a terminal with a serial console in it. There is no
  # monitor socket (stdio holds it), and the recorded pid is vm.sh rather than
  # qemu — so "stopping" it from here can only mean signalling that shell, which
  # is not a clean guest shutdown. Say so instead of pretending.
  if [[ "$(state_field attached)" == true && "$FORCE" != true ]]; then
    echo "that session is attached to a serial console (started without --ssh)."
    echo "  stop it there: type 'poweroff' in the guest, or Ctrl-A x"
    echo "  or force it:   kata vm --stop --force   (no bake, no fs sync)"
    exit 1
  fi

  if [[ "$FORCE" == true ]]; then
    echo "[!] forced stop of qemu (pid ${pid}) — NOT a clean shutdown:"
    echo "    the guest filesystem is not synced and --to will NOT bake a base."
    # The marker is what actually guarantees the second half of that sentence.
    # qemu treats SIGTERM as a shutdown request and exits **0**, so the
    # supervisor's "rc == 0 means the guest powered off cleanly" test cannot
    # tell a forced stop from a real poweroff — it would happily flatten a
    # half-provisioned session over the warm base you were replacing. So say it
    # out loud, in a file the supervisor checks before baking.
    if [[ -n "$rd" && -d "$rd" ]]; then : >"${rd}/no-bake"; fi
    kill -TERM "$pid" 2>/dev/null || true
    # Escalate rather than hang: a wedged qemu ignores TERM, and this path has
    # already given up on a clean shutdown.
    local j
    for j in 1 2 3 4 5; do
      pid_alive "$pid" || break
      sleep 1
    done
    if pid_alive "$pid"; then
      echo "[!] still alive after SIGTERM — SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  else
    # ACPI power button via the qemu monitor. systemd-logind in the guest
    # handles it as a normal poweroff, so the fs syncs, qemu exits 0, and the
    # session stays eligible for the --to bake. No password needed, unlike
    # ssh'ing in to run `poweroff`.
    local sock="${rd}/monitor.sock"
    [[ -S "$sock" ]] || {
      echo "no monitor socket at ${sock} (session started before --stop existed?)"
      echo "  stop it from inside: kata ssh, then poweroff"
      echo "  or force it:         kata vm --stop --force   (no bake)"
      exit 1
    }
    echo "[*] ACPI poweroff → qemu monitor ..."
    qemu_monitor_send "$sock" system_powerdown || {
      echo "[!] could not talk to the monitor socket (need socat or python3)"
      exit 1
    }
  fi

  local i
  for i in $(seq 1 90); do
    pid_alive "$pid" || {
      echo "[ok] session stopped"
      return 0
    }
    sleep 1
  done
  echo "[!] still running after 90s. The guest may be hung."
  echo "    force it (no bake): kata vm --stop --force"
  exit 1
}

case "$ACTION" in
status)
  cmd_status
  exit 0
  ;;
stop)
  cmd_stop
  exit 0
  ;;
esac

# One session at a time: two guests would race for $VM_IP, the virtiofs shares
# and (with --gpu) the card itself. Refuse with the state, rather than let the
# second one boot into a confusing half-broken network.
if session_alive; then
  echo "a session is already running (qemu pid $(state_field pid), base $(state_field base))"
  echo "  connect: kata ssh        status: kata vm --status        stop: kata vm --stop"
  exit 1
fi
if [[ -e "$VM_STATE_FILE" ]]; then clear_stale_session; fi

# The guest's home is the persistent agent tree, and it is the only place the
# agent should ever be given read-write: a tree YOU own would mean
# reviewing-then-running code the agent wrote, which the git interchange exists to
# prevent. One path, from config, so there is no second candidate for two commands
# to disagree about; --home overrides it for this run.
[[ -n "$HOME_DIR" ]] || HOME_DIR="$MOUNT_HOME"
[[ -d "$HOME_DIR" ]] || {
  echo "agent home not found: $HOME_DIR"
  echo "  plain tree on this disk:  sudo kata disk local-init"
  echo "  encrypted key:            sudo kata disk mount"
  echo "                            then MOUNT_HOME=<its @home> in config.local.sh"
  echo "  or for this run only:     kata vm --home PATH"
  exit 1
}
[[ $EUID -eq 0 ]] || {
  echo "run as root (sudo)"
  exit 1
}

# --ssh reaches the guest over the bridge at $VM_IP; --no-int leaves no NIC.
if [[ "$SSH_MODE" == true ]]; then
  [[ "$INTERNET_ENABLED" == true ]] || {
    echo "--ssh needs the bridge NIC — not compatible with --no-int"
    exit 1
  }
  command -v ssh >/dev/null || {
    echo "--ssh needs an ssh client (install openssh)"
    exit 1
  }
  # The detach is `setsid vm-supervise.sh`; without it the guest would stay
  # tied to this terminal, which is the thing --ssh exists to stop.
  command -v setsid >/dev/null || {
    echo "--ssh needs setsid (util-linux) to detach the session"
    exit 1
  }
fi

# Foot-gun guard (config.sh): refuse the workspace and any rw mount under your
# real home. --ro is exempt on purpose: virtiofsd runs as root and reads your
# home fine, the in-guest agent sees only the mounted subtree (never the rest of
# /home), and a hypervisor escape lands as the agent uid, which agent_isolate
# already fences. Read-only ingress of a real project is the intended workflow,
# so the guard there would be friction with no wall behind it. The workspace
# (rw) and --rw stay guarded — those are writes into your tree. The workspace
# check is near-vacuous now that it defaults to $MOUNT_HOME, but it is what
# stands behind an explicit --workspace, which is the only way to get it wrong.
refuse_under_home "$HOME_DIR"
for p in "${EXTRA_RW[@]}"; do refuse_under_home "$p" --rw; done

# Storage guard (config.sh). Only the paths we're actually about to use are
# checked, so an explicit `--home /tmp/scratch` demands nothing — but a home or
# mount that is only STANDING IN for an absent mount (right path, wrong owner) is
# refused rather than silently written to the bare mountpoint on the root fs.
require_storage "$HOME_DIR" "${EXTRA_RO[@]}" "${EXTRA_RW[@]}"

# --- Base resolution (one namespace: $VM_BASES_DIR) ------------------------
# Every base — including the blank one build-base.sh produces — is
# $VM_BASES_DIR/<name>.qcow2, so `--from` and `kata bases` can never disagree
# about what exists. VM_BASES_DIR must never be agent-writable: vm.sh parses
# base qcow2s as root, so an agent-writable base is a root-code-exec surface
# (threat: base-poisoning) — which is why it is a constant under $VM_IMAGES_DIR
# and never under $MOUNT_HOME, no matter how the home is configured.
[[ -n "$FROM_NAME" ]] || FROM_NAME="$VM_BASE_NAME"
require_storage "$VM_BASES_DIR"
mkdir -p "$VM_BASES_DIR"

BACKING="$(base_img "$FROM_NAME")"
[[ -f "$BACKING" ]] || {
  echo "base image missing: $BACKING"
  echo
  echo "  bases in ${VM_BASES_DIR}:"
  ls -1 "$VM_BASES_DIR"/*.qcow2 2>/dev/null | sed 's#.*/#    #; s#\.qcow2$##' ||
    echo "    (none)"
  echo
  echo "  build the blank base:  kata build-base"
  echo "  or pick another:       kata vm --from NAME"
  exit 1
}

command -v qemu-system-x86_64 >/dev/null || {
  echo "install qemu (qemu-full / qemu-system-x86 / qemu-kvm)"
  exit 1
}
command -v qemu-img >/dev/null || {
  echo "install qemu-img (qemu-utils on Debian)"
  exit 1
}

# virtiofsd location varies: Arch ships it at /usr/lib/virtiofsd; Debian/Fedora
# typically at /usr/libexec/virtiofsd. Fall through to PATH last.
VIRTIOFSD=""
for c in /usr/lib/virtiofsd /usr/libexec/virtiofsd "$(command -v virtiofsd 2>/dev/null || true)"; do
  [[ -n "$c" && -x "$c" ]] && {
    VIRTIOFSD="$c"
    break
  }
done
[[ -n "$VIRTIOFSD" ]] || {
  echo "virtiofsd not found (looked in /usr/lib, /usr/libexec, PATH)"
  exit 1
}

# --- Base sanity: CA drift and stale parents -------------------------------
# Both are cases where the image is fine, the host is fine, and the PAIR is
# wrong — which is why they show up as symptoms that name the wrong component.
if [[ "$INTERNET_ENABLED" == true ]]; then
  BASE_CA="$(base_ca "$FROM_NAME")"
  HOST_CA="$(ca_fingerprint)"
  # Empty on either side is UNKNOWN, never mismatch: bases baked before the
  # field existed have none, and a host that has never run `kata up` has no CA.
  # Refusing on unknown would make every pre-existing base unbootable.
  if [[ -n "$BASE_CA" && -n "$HOST_CA" && "$BASE_CA" != "$HOST_CA" ]]; then
    gate "$FORCE" "base '${FROM_NAME}' trusts a different mitmproxy CA than the one running" <<EOF
base: ${BASE_CA}   host: ${HOST_CA}

net-up.sh regenerates the CA whenever ${PROXY_CA_PEM} is missing, and the
image's trust store is baked in at build time. Every TLS request in the guest
would fail certificate validation — a symptom that names the proxy rather than
the image, which is how it eats an afternoon.

fix: kata build-base          (rebuild against the current CA)
     kata vm --force …        (boot anyway; expect TLS errors)
EOF
  fi
fi

# Re-baking a base whose own parent has moved on perpetuates the staleness, and
# the result is indistinguishable from a good base afterwards — `cuda v2 ← base
# v1` looks authoritative next to a `base` that is now v3. This is the shape of
# the bug that cost an afternoon: a months-old image quietly answering for a
# fresh one. It is a refusal rather than a warning only when --to is given,
# because that is the case that writes the confusion down.
if [[ -n "$TO_NAME" ]] && base_stale "$FROM_NAME"; then
  # Summary stays force-neutral: gate() prefixes it with error:/warning:, so a
  # summary containing the word "refusing" would contradict the warning form.
  gate "$FORCE" "--to ${TO_NAME} would bake on top of a stale base" <<EOF
$(base_describe "$FROM_NAME")

Baking on top of it carries the old parent forward, and nothing afterwards shows
that the result is built on an image you have already replaced.

fix: kata vm --from ${VM_BASE_NAME} --to ${TO_NAME} …   (rebuild on current)
     kata vm --force …                                 (bake anyway)
EOF
fi

# --- Egress preflight ------------------------------------------------------
# The guest has exactly one way out, so "can it actually get out" is worth
# proving BEFORE spending a boot on finding out. Three checks, and they prove
# different things — none of them subsumes another:
#
#   bridge       the link the guest's only NIC attaches to.
#   agent_vm     the session gate. The guest's packets arrive over the bridge
#                and are matched by `iifname virbr-agent` rules in this table;
#                without it the chain's terminal drop is all that is left.
#   proxy_state  the proxy ANSWERS. This is the check the old code was missing,
#                and it is the one that would have caught the IPv6 episode:
#                `nft list table` and `ip link show` were both true for an
#                evening while every request through the proxy hung forever.
#                A structure check tells you the pipe is plumbed; only a request
#                tells you something is on the other end.
#
# Conversely proxy_state cannot replace the nft check — it is issued from the
# host to a local address, so it never crosses `agent_vm input`. Guest-side
# egress is only ever really proven from inside a guest (audit-egress.sh).
if [[ "$INTERNET_ENABLED" == true ]]; then
  ip link show "$BRIDGE" &>/dev/null || refuse "bridge ${BRIDGE} is missing" <<EOF
The guest's only NIC has nothing to attach to.
fix: sudo kata up
EOF

  nft list table inet agent_vm &>/dev/null || refuse "nft table inet agent_vm is missing" <<EOF
That table IS the session gate: the guest's packets arrive over ${BRIDGE} and
are matched there. Without it they hit the terminal drop and nothing works.
fix: sudo kata up
EOF

  # One probe, one variable: this used to call proxy_state twice to render the
  # unexpected-code message, i.e. two HTTP requests to answer one question.
  PSTATE="$(proxy_state)"
  case "$PSTATE" in
  ok) : ;;
  down) refuse "nothing is listening on ${HOST_IP}:${PROXY_PORT}" <<EOF
The guest's only route out is down. Every request in the session would hang.
fix: sudo kata up
EOF
    ;;
  wedged) refuse "mitmproxy on ${HOST_IP}:${PROXY_PORT} accepts connections but does not answer" <<EOF
This is the failure that reads as a broken allowlist and is not one. Read the
IPv6 trap in CLAUDE.md before debugging the addon.
fix: sudo kata down && sudo kata up
EOF
    ;;
  # Anything that is not 403 means the allowlist addon did not reject an
  # unresolvable host — whatever is on that port is not our gate. Boot against
  # it and the sandbox has unfiltered egress while every structural check is
  # still green, which is the worst failure shape this project has.
  *) refuse "the proxy on ${HOST_IP}:${PROXY_PORT} answered ${PSTATE}, expected 403" <<EOF
Something is listening there, but it did not deny an unresolvable host — so it
is not the allowlist addon, and the sandbox would have UNFILTERED egress.
fix: sudo kata down && sudo kata up   (then: podman logs agent-proxy)
EOF
    ;;
  esac
fi

# --- GPU passthrough (VFIO) -----------------------------------------------
# Every device in the GPU's IOMMU group must be bound to vfio-pci, and must be
# passed to the guest together: VFIO opens groups, not devices. gpu-mode.sh
# arranges the binding at boot; here we only verify and assemble the args, so a
# misconfigured host fails with a sentence instead of a qemu backtrace.
VFIO_ARGS=()
if [[ "$GPU_MODE" == true ]]; then
  GPU_ADDR="$(gpu_addr)"
  [[ -n "$GPU_ADDR" ]] || {
    echo "--gpu: no NVIDIA GPU found (set GPU_PCI_ADDR to override autodetection)"
    exit 1
  }
  mapfile -t GPU_GROUP < <(gpu_group_devices "$GPU_ADDR") || {
    echo "--gpu: could not read the IOMMU group for $GPU_ADDR (is the IOMMU on?)"
    exit 1
  }
  for d in "${GPU_GROUP[@]}"; do
    drv="$(pci_driver "$d")"
    if [[ "$drv" != "vfio-pci" ]]; then
      echo "--gpu: $d is bound to '${drv:-<none>}', not vfio-pci."
      echo
      echo "  The whole IOMMU group has to be on vfio-pci before the guest can"
      echo "  take any of it. Switch the host over and reboot:"
      echo "      sudo ${HERE}/gpu-mode.sh sandbox && sudo reboot"
      echo "  Check the current state any time with: ${HERE}/gpu-mode.sh status"
      exit 1
    fi
    # romfile= (empty) suppresses the device's option ROM — same trick the NIC
    # already uses. This became REQUIRED the moment `-vga none` landed
    # (threat: qemu-device-surface), and the failure is worth recording because
    # it looks nothing like its cause:
    #
    #   Removing the emulated stdvga made the passed-through GPU the only
    #   VGA-class device on the bus. SeaBIOS therefore promoted it to primary
    #   display and tried to EXECUTE its option ROM to init the console. On a
    #   laptop dGPU that ROM is routinely incomplete — the real VBIOS lives in
    #   the system firmware, which POSTed the card before we ever saw it — so
    #   SeaBIOS wedged. One vCPU pegged, and `serial.log` STAYED ZERO BYTES:
    #   SeaBIOS writes to the VGA console and debugcon, never to ttyS0, so
    #   nothing reaches the serial log until the Linux kernel starts. An empty
    #   serial log with a live qemu means a firmware-stage hang, not a slow boot.
    #
    # Before `-vga none` this could not happen: stdvga was primary and the
    # card's ROM was never executed, only exposed. We keep exposing nothing and
    # let the guest's nvidia driver read the VBIOS off the card itself, which is
    # what it does on Linux anyway. If a guest ever fails to initialise the card,
    # that is what GPU_ROMFILE is for — dump the real VBIOS and point at it.
    #
    # GPU_ROMFILE applies to the DISPLAY function only. It used to be appended to
    # VFIO_ARGS[-1], which is the last device in the IOMMU group — i.e. the HDMI
    # audio function, not the GPU. Never caught because the variable has never
    # been set; it would have failed as "the vBIOS did nothing".
    rom="romfile="
    if [[ -n "${GPU_ROMFILE:-}" && "$d" == "$GPU_ADDR" ]]; then
      [[ -r "$GPU_ROMFILE" ]] || {
        echo "--gpu: GPU_ROMFILE not readable: $GPU_ROMFILE"
        exit 1
      }
      rom="romfile=${GPU_ROMFILE}"
    fi
    VFIO_ARGS+=(-device "vfio-pci,host=${d},${rom}")
  done
  echo "[+] GPU passthrough: ${GPU_GROUP[*]}"
fi

SESSION="session-$$-$(date +%s)"
OVERLAY="${VM_IMAGES_DIR}/${SESSION}.qcow2"
RUN_DIR="${VM_RUN_ROOT}/${SESSION}"
mkdir -p "$VM_IMAGES_DIR" "$RUN_DIR"

VFS_PIDS=()
QEMU_CLEAN=0    # set to 1 only after qemu exits 0 (clean guest poweroff)
QEMU_PID=""     # set in --ssh mode, where qemu runs in the background
HANDED_OFF=0    # set once vm-supervise.sh owns the session (see --ssh below)

cleanup() {
  set +e
  # In detached (--ssh) mode the supervisor owns the teardown: it holds qemu as
  # its own child, and it is the thing still alive when this script returns. If
  # we ran the cleanup here we would kill the virtiofsds and delete the overlay
  # out from under a perfectly healthy guest.
  [[ $HANDED_OFF -eq 1 ]] && return 0
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
  fi
  [[ -n "$TO_NAME" && $QEMU_CLEAN -eq 1 ]] && save_base "$OVERLAY" "$TO_NAME" "$FROM_NAME" "$GPU_MODE"
  for p in "${VFS_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -f "$VM_STATE_FILE"
  rm -rf "$RUN_DIR"
  rm -f "$OVERLAY"
}
trap cleanup EXIT
# On signal, exit (→ EXIT trap) without setting QEMU_CLEAN, so an interrupted
# session is never baked into a base — only a clean guest poweroff is.
#
# HUP is in the list because of what we found in /run afterwards: a bash killed
# by an UNTRAPPED signal does not run its EXIT trap, so closing the terminal on
# an attached session left the state file, the run dir and the overlay behind,
# and the next launch saw a session that wasn't there. Trapping it turns a
# closed terminal into an ordinary teardown.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Overlay size must match what build-base.sh grew the base to, or the guest's
# partition table and the virtual disk disagree.
qemu-img create -F qcow2 -b "$BACKING" -f qcow2 "$OVERLAY" "$VM_DISK_SIZE" >/dev/null

# --- virtiofsd per mount --------------------------------------------------
VFS_ARGS=()
start_vfs() {
  local idx="$1" dir="$2" tag="$3" ro="$4"
  local sock="${RUN_DIR}/vfs${idx}.sock"
  local extra=()
  [[ "$ro" == true ]] && extra+=(--readonly)
  # Ignore HUP across the fork, `nohup`-style: an ignored disposition is
  # inherited through fork+exec, so these survive the launching terminal being
  # closed. That matters for a detached (--ssh) session, where the guest keeps
  # running: without it, closing the terminal would take the virtiofsds — and
  # therefore the guest's HOME — out from under a live VM. Attached sessions
  # kill them explicitly in cleanup(), so nothing is leaked either way.
  trap '' HUP
  "$VIRTIOFSD" \
    --socket-path="$sock" \
    --shared-dir="$dir" \
    --sandbox=chroot \
    "${extra[@]}" >"${RUN_DIR}/vfs${idx}.log" 2>&1 &
  VFS_PIDS+=("$!")
  trap 'exit 129' HUP
  for _ in $(seq 1 20); do
    [[ -S "$sock" ]] && break
    sleep 0.1
  done
  [[ -S "$sock" ]] || {
    echo "virtiofsd($tag) failed — see ${RUN_DIR}/vfs${idx}.log"
    exit 1
  }
  VFS_ARGS+=(
    -chardev "socket,id=vfs${idx},path=${sock}"
    -device "vhost-user-fs-pci,chardev=vfs${idx},tag=${tag}"
  )
}

# Tag `workspace`, mounted by the guest at /home/agent (guest/cloud-init). The
# tag keeps its old name so warm bases built before that change still mount it
# somewhere instead of silently mounting nothing.
start_vfs 0 "$HOME_DIR" workspace false
i=1
for p in "${EXTRA_RO[@]}"; do
  [[ -d "$p" ]] || {
    echo "ro mount not found: $p"
    exit 1
  }
  start_vfs "$i" "$p" "ro_${i}" true
  i=$((i + 1))
done
for p in "${EXTRA_RW[@]}"; do
  [[ -d "$p" ]] || {
    echo "rw mount not found: $p"
    exit 1
  }
  start_vfs "$i" "$p" "rw_${i}" false
  i=$((i + 1))
done

# --- Network --------------------------------------------------------------
NET_ARGS=(-nic none)
if [[ "$INTERNET_ENABLED" == true ]]; then
  NET_ARGS=(
    -netdev "bridge,id=n0,br=${BRIDGE}"
    -device "virtio-net-pci,netdev=n0,romfile="
  )
fi

# Drop qemu to the agent uid after setup (threat: qemu-uid-drop). An escape lands
# as the agent (caught by agent_isolate) instead of root — the worst landing in
# the threat table becomes the best, for free. Safe because every privileged
# resource is acquired during init *as root, before the drop*: /dev/kvm (accel
# init), the bridge tap (qemu-bridge-helper, setuid, at netdev init), the
# virtiofsd vhost-user sockets (chardev connect at startup), and the overlay +
# its 700 you-owned backing base (opened rw/ro at block-layer init). qemu holds
# those fds across the drop; the guest vCPUs run as the agent. The parent bash
# (this script) stays root, so cleanup/save_base still work.
# Needs qemu >= 8.0 for `-run-with user=`. Fail loud if absent rather than
# silently running qemu as root (set ALLOW_QEMU_ROOT=1 to override on purpose).
RUNAS_ARGS=()
id -u "$AGENT_USER" >/dev/null 2>&1 || {
  echo "agent user '$AGENT_USER' missing — needed to drop qemu privileges"
  exit 1
}
if qemu-system-x86_64 -help 2>/dev/null | grep -q 'run-with'; then
  RUNAS_ARGS=(-run-with "user=${AGENT_USER}")
elif [[ "${ALLOW_QEMU_ROOT:-}" == 1 ]]; then
  echo "[!] qemu lacks '-run-with user=' — running qemu AS ROOT (ALLOW_QEMU_ROOT=1); an escape would land as root"
else
  echo "qemu lacks '-run-with user=' (need >= 8.0). Refusing to run qemu as root."
  echo "  upgrade qemu, or re-run with ALLOW_QEMU_ROOT=1 to override (escape would land as root)."
  exit 1
fi

# Session metadata: consumed by the dashboard, by `kata ssh`, and by this
# script's own --status/--stop and one-session-at-a-time check. World-readable,
# paths only. `pid` is filled in below, once qemu is actually running — a state
# file with no live pid is what `session_alive` treats as a leftover.
# Best-effort: a missing jq costs you --status and the dashboard's VM pane,
# never a failed launch.
write_state() { # $1 = pid to watch ("" = none yet), $2 = attached? (true|false)
  command -v jq >/dev/null || return 0
  mkdir -p "$VM_RUN_ROOT"
  local ro_json='[]' rw_json='[]'
  ((${#EXTRA_RO[@]})) && ro_json=$(printf '%s\n' "${EXTRA_RO[@]}" | jq -R . | jq -s .)
  ((${#EXTRA_RW[@]})) && rw_json=$(printf '%s\n' "${EXTRA_RW[@]}" | jq -R . | jq -s .)
  jq -n \
    --arg base "$FROM_NAME" \
    --arg backing "$BACKING" \
    --arg overlay "$OVERLAY" \
    --arg mem "$MEM" \
    --arg home "$HOME_DIR" \
    --arg to "$TO_NAME" \
    --arg session "$SESSION" \
    --arg rundir "$RUN_DIR" \
    --arg pid "${1:-}" \
    --argjson attached "${2:-false}" \
    --argjson smp "$SMP" \
    --argjson internet "$INTERNET_ENABLED" \
    --argjson gpu "$GPU_MODE" \
    --argjson ro "$ro_json" \
    --argjson rw "$rw_json" \
    '{base: $base, backing: $backing, overlay: $overlay, mem: $mem,
          smp: $smp, internet: $internet, gpu: $gpu, home: $home, to: $to,
          session: $session, rundir: $rundir,
          attached: $attached,
          pid: (if $pid == "" then null else ($pid|tonumber) end),
          ro: $ro, rw: $rw}' \
    >"$VM_STATE_FILE" 2>/dev/null || true
  chmod 0644 "$VM_STATE_FILE" 2>/dev/null || true
  return 0
}
write_state "" false

echo "VM | mem=${MEM} smp=${SMP} internet=${INTERNET_ENABLED} gpu=${GPU_MODE}"
echo "    home=${HOME_DIR} → /home/${AGENT_USER}"
echo "    base=$(base_describe "$FROM_NAME")"
echo "         ${BACKING}"
echo "    overlay=${OVERLAY}  (throwaway, ${VM_DISK_SIZE} max, on host /)"
if [[ -n "$TO_NAME" ]]; then
  echo "    will bake → ${VM_BASES_DIR}/${TO_NAME}.qcow2 on clean poweroff"
  # Re-baking a name is the normal way to refresh a warm base, so this is a
  # warning and not a guard — but the bake is destructive and silent, and the
  # thing it destroys is usually an hour of downloads (a CUDA base is 15G+).
  # Worth one line saying what you are about to trade away.
  if [[ -e "$(base_img "$TO_NAME")" ]]; then
    echo "         REPLACES the existing $(base_describe "$TO_NAME") ($(du -h "$(base_img "$TO_NAME")" 2>/dev/null | cut -f1))"
  fi
fi
echo "    extra ro=${#EXTRA_RO[@]} rw=${#EXTRA_RW[@]}"
[[ "$INTERNET_ENABLED" == true && "$SSH_MODE" != true ]] && echo "    tip: for nvim/TUIs, re-run with --ssh (this serial console is poor for them)"

# VFIO pins the entire guest RAM (the device can DMA to any of it) and charges
# those pages to the process's RLIMIT_MEMLOCK. Raise it before qemu starts, or
# `--gpu` dies mid-firmware. The sequence, because it is not obvious:
#
#   1. init, as root: the vfio memory listener maps all of guest RAM. root has
#      CAP_IPC_LOCK so the limit is not consulted — but mm->locked_vm is still
#      charged the full size.
#   2. `-run-with user=` drops to the agent uid at the end of qemu_init, i.e.
#      AFTER device realize.
#   3. runtime: every memory-region change triggers a fresh VFIO_IOMMU_MAP_DMA.
#      SeaBIOS shadowing the PAM window at 0xc0000 is the first one. No
#      CAP_IPC_LOCK any more, and the limit is whatever the invoking shell had
#      (8M by default) against a locked_vm that already holds all of guest RAM
#      → -ENOMEM → "vfio: DMA mapping failed, unable to continue", qemu aborts.
#
# So an 8G map succeeds and a 96K one kills the guest. Bounded at guest RAM +
# 1G rather than `unlimited`: an escaped qemu at the agent uid should not be
# able to pin arbitrary host memory. The limit is inherited across the uid drop.
if [[ "$GPU_MODE" == true ]]; then
  ulimit -l $(($(mem_kib "$MEM") + 1048576))
fi

# share=on: virtiofs needs it. prealloc with --gpu is no longer load-bearing
# (the memlock block above is what makes VFIO work) — it just faults the guest's
# pages in up front, so the cost is paid at boot instead of as stalls during the
# run. Off for CPU sessions, where it would only make startup slower.
MEM_OBJ="memory-backend-memfd,id=mem,size=${MEM},share=on"
[[ "$GPU_MODE" == true ]] && MEM_OBJ="${MEM_OBJ},prealloc=on"

# --- Emulated device surface (threat: qemu-device-surface) -------------------
# Every emulated device is attack surface reachable from guest userspace, and
# qemu instantiates a pile of them by default that this guest never touches.
# Measured with `info qtree`, not assumed: 26 device types before this block,
# 14 after.
#
# Two of these are not generic hygiene. They come from specific bugs in
# knowledge/vm-escape-2026-08.md, where an agent escaped qemu/KVM three times:
#
#   -nodefaults -vga none
#     q35 instantiates a stdvga with 16MB of vgamem whether or not a display
#     backend exists. `-display none` (which we already passed) removes the
#     BACKEND, not the DEVICE — verified in qtree. His fourth QEMU bug was a
#     96-byte panning buffer overflowed by a 1024-byte render; it went unused
#     only because no display listener reached the renderer. The device was
#     still there. This removes the device. We lose nothing: the console is
#     serial, and under --gpu the guest has the real card.
#
#   smm=off
#     The first link of his final chain was "VAPIC's unchecked ROM alias could
#     overlap locked SMRAM" → SMRAM exposure and attacker-controlled SMM
#     execution. The kvmvapic device has no off switch (checked `-machine
#     q35,help`) but the described impact needs SMRAM to exist. We boot SeaBIOS
#     with no pflash and no secure boot, so nothing here needs SMM.
#     THIS IS THE ONE FLAG THAT COULD PLAUSIBLY BREAK BOOT. If a guest stops
#     coming up after a qemu or image change, bisect from here first.
#
# The rest is dead weight we can prove unused: we boot virtio-blk (sata=off,
# and -nodefaults drops the default ide-cd), have no graphical input
# (i8042=off, and with it ps2-kbd/ps2-mouse), no USB, no parallel port, no
# SMBus (smbus=off, and with it 8 smbus-eeprom), and Ubuntu runs on kvm-clock
# (hpet=off). vmport=off removes the VMware backdoor port and vmmouse.
#
# NOT removed, for the record: kvmvapic (no switch), i8257 DMA, mc146818rtc,
# isa-pit, isa-pcspk. And `-cpu host` stays — narrowing it would shrink the
# guest-visible feature surface but costs the CPU features torch wants.
#
# The option list itself lives in config.sh, because build-base.sh boots a guest
# too and two copies of it would eventually disagree.
QEMU_MACHINE="q35,accel=kvm,${QEMU_MACHINE_OPTS}"

QEMU_BASE=(
  qemu-system-x86_64
  -nodefaults
  -machine "$QEMU_MACHINE"
  -vga none
  -cpu host
  -m "$MEM" -smp "$SMP"
  -drive "file=${OVERLAY},if=none,id=hd0,format=qcow2"
  -device virtio-blk-pci,drive=hd0,bootindex=1
  -object "$MEM_OBJ"
  -numa node,memdev=mem
  "${VFS_ARGS[@]}"
  "${NET_ARGS[@]}"
  "${VFIO_ARGS[@]}"
  "${RUNAS_ARGS[@]}"
)

QEMU_RC=0
if [[ "$SSH_MODE" == true ]]; then
  # --- Detached session -----------------------------------------------------
  # The guest OUTLIVES this command. qemu is started by vm-supervise.sh in its
  # own session (setsid), which then owns everything this script's cleanup()
  # would have done: waiting on qemu, baking --to on a clean poweroff, killing
  # the virtiofsds, and removing the overlay + state file.
  #
  # Why not just keep vm.sh in the foreground and skip the poweroff on exit:
  # because the terminal that launched it is then load-bearing. Closing it
  # SIGHUPs the process group and takes the guest with it — including the
  # virtiofsds, i.e. the guest's home. Detaching is what makes "ssh in from
  # three terminals, close them all, come back with kata ssh" actually work.
  SERIAL_LOG="${RUN_DIR}/serial.log"
  SUP_LOG="${RUN_DIR}/supervise.log"
  QEMU_BASE+=(
    -display none
    -serial "file:${SERIAL_LOG}"
    # HMP over a unix socket, so `kata vm --stop` can press the ACPI power
    # button without needing the guest's password over ssh.
    -monitor "unix:${RUN_DIR}/monitor.sock,server=on,wait=off"
  )

  # Hand the exact argv over rather than reconstructing it: `declare -p` is
  # lossless for arrays with spaces/quotes in them, and the run dir is
  # root-owned under /run.
  {
    echo "# generated by vm.sh — consumed by vm-supervise.sh"
    printf 'HOST_USER=%q\n' "${HOST_USER:-}"
    printf 'VM_BASES_DIR=%q\n' "$VM_BASES_DIR"
    printf 'MOUNT_HOME=%q\n' "$HOME_DIR"
    printf 'SESSION=%q\n' "$SESSION"
    printf 'RUN_DIR=%q\n' "$RUN_DIR"
    printf 'OVERLAY=%q\n' "$OVERLAY"
    printf 'FROM_NAME=%q\n' "$FROM_NAME"
    printf 'TO_NAME=%q\n' "$TO_NAME"
    printf 'GPU_MODE=%q\n' "$GPU_MODE"
    printf 'MEM=%q\n' "$MEM"
    printf 'VM_STATE_FILE=%q\n' "$VM_STATE_FILE"
    declare -p QEMU_BASE VFS_PIDS
  } >"${RUN_DIR}/session.env"

  echo "    serial log → ${SERIAL_LOG}"
  echo "[*] booting headless, waiting for ssh on ${VM_IP}:22 ..."
  setsid "${HERE}/vm-supervise.sh" "$RUN_DIR" </dev/null >>"$SUP_LOG" 2>&1 &
  HANDED_OFF=1

  ssh_ready=0
  for _ in $(seq 1 180); do
    if (exec 3<>"/dev/tcp/${VM_IP}/22") 2>/dev/null; then
      ssh_ready=1
      break
    fi
    # The supervisor removes the state file when qemu is gone, so a vanished
    # session means the boot died — don't sit here for three minutes.
    if [[ ! -e "$VM_STATE_FILE" ]] && [[ -s "$SUP_LOG" ]]; then
      echo "[!] the session exited during boot:"
      tail -20 "$SUP_LOG" | sed 's/^/    /'
      exit 1
    fi
    sleep 1
  done
  [[ $ssh_ready -eq 1 ]] || {
    echo "[!] ssh never came up on ${VM_IP}:22"
    echo "    serial:     ${SERIAL_LOG}"
    echo "    supervisor: ${SUP_LOG}"
    echo "    the guest is still running — kata vm --status / --stop"
    exit 1
  }

  echo "[ok] session up; it keeps running when you exit the shell — reconnect: kata ssh (as many terminals as you like), stop: poweroff inside or kata vm --stop"
  exec "${HERE}/ssh.sh"
fi

# --- Attached session (serial console) -------------------------------------
# qemu in the foreground, cleanup() in this shell. Ctrl-C or a closed terminal
# takes the guest down with it — which is the right behaviour for a console
# session, and the reason --ssh detaches instead.
#
# The pid recorded is THIS script's, not qemu's: qemu has to stay in the
# foreground to own the terminal (`-serial mon:stdio`), so there is no `$!` to
# record, and vm.sh is alive for exactly as long as the session is. That is all
# `session_alive` needs, and it is why --stop refuses to touch an attached
# session: signalling this shell is not a clean guest shutdown.
write_state "$$" true
"${QEMU_BASE[@]}" -nographic -serial mon:stdio || QEMU_RC=$?

# Only a clean guest poweroff (rc 0) is eligible to be baked into a base.
if [[ $QEMU_RC -eq 0 ]]; then
  QEMU_CLEAN=1
else
  echo "[!] qemu exited ${QEMU_RC} — session not eligible for --to bake"
fi
