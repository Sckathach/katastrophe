#!/usr/bin/env bash
# vm.sh — the sandbox: a qemu/KVM guest with the agent home over virtiofs, a NIC
# on the gated bridge, and optionally the dGPU via VFIO. Run `kata up` first.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

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
usage: kata vm [options]

qemu/KVM VM. The persistent agent home (${MOUNT_HOME}) is mounted over virtiofs
AS the guest's /home/agent, so ~/.claude, ~/.cache/huggingface and every
checkout survive a session. Egress via mitmproxy on ${BRIDGE}.

  --home PATH       host dir to mount as the guest's /home/agent (default
                    \$MOUNT_HOME). Must be agent-owned: handing the agent a tree
                    YOU own means reviewing-then-running code it wrote.
  --gpu             hand the physical GPU to the guest via VFIO. Needs
                    'kata gpu-mode sandbox' and a reboot first.
  --ssh             boot headless in the BACKGROUND and ssh into agent@${VM_IP}.
                    The guest outlives the shell: reconnect with 'kata ssh' from
                    any number of terminals; stop with 'poweroff' inside or
                    'kata vm --stop'. Not compatible with --no-int.
  --no-int          no network attached
  --ro PATH         extra ro mount; tag ro_N, appears at /mnt/ro_N
  --rw PATH         extra rw mount; tag rw_N, appears at /mnt/rw_N
  --mem SIZE        guest memory (default ${VM_MEM})
  --smp N           guest vCPUs (default ${VM_SMP})
  --from NAME       boot off the warm base ${VM_BASES_DIR}/NAME.qcow2
                    (default: ${VM_BASE_NAME}, the one 'kata build-base' makes)
  --to NAME         on clean shutdown, flatten this session into base NAME,
                    versioned and tagged with its parent. Replaces atomically.
  --force           override a launch guard (CA drift, stale parent). Each one
                    says what it protects you from; none protects you from the
                    guest.

  --status          show the running session (no root needed)
  --stop            ACPI-poweroff the running session (clean → --to still bakes)
  --stop --force    SIGTERM qemu instead. Not clean: no bake, no fs sync.

Bases are warm, immutable starting points (e.g. CUDA baked in); each session
runs on a throwaway overlay. First bake: --to cuda, run 'sudo kata-install-cuda'
inside, poweroff. Then: --from cuda. Bases hold SYSTEM state only — the home is
a mount, so a login or a model is never baked in. 'kata bases' lists them.

--gpu needs a reboot to switch sides: systemd-logind holds a DRM fd on the card,
so the only way to free it is to never create the DRM node ('kata gpu-mode').
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
  --home | --workspace) # --workspace: the old name
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
# $VM_STATE_FILE answers "is a session running, and what is it" for --status,
# --stop, `kata ssh` and the one-session check. Read via state_field (lib.sh).

# Only called when the pid is confirmed dead, and only as root (it is in /run).
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
  # From the state file, not this invocation's flags: believe the session.
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

  # An attached session has no monitor socket (stdio holds it) and its recorded
  # pid is this script, not qemu: signalling it is not a clean shutdown.
  if [[ "$(state_field attached)" == true && "$FORCE" != true ]]; then
    echo "that session is attached to a serial console (started without --ssh)."
    echo "  stop it there: type 'poweroff' in the guest, or Ctrl-A x"
    echo "  or force it:   kata vm --stop --force   (no bake, no fs sync)"
    exit 1
  fi

  if [[ "$FORCE" == true ]]; then
    echo "[!] forced stop of qemu (pid ${pid}) — NOT a clean shutdown:"
    echo "    the guest filesystem is not synced and --to will NOT bake a base."
    # qemu exits 0 on SIGTERM, which the supervisor would read as a clean
    # poweroff and bake. The no-bake marker is the veto.
    if [[ -n "$rd" && -d "$rd" ]]; then : >"${rd}/no-bake"; fi
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      pid_alive "$pid" || break
      sleep 1
    done
    if pid_alive "$pid"; then
      echo "[!] still alive after SIGTERM — SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
    fi
  else
    # ACPI power button: a normal guest poweroff, so fs sync, rc 0, bake allowed.
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

# One session at a time: two guests would race for $VM_IP, the shares and the GPU.
if session_alive; then
  echo "a session is already running (qemu pid $(state_field pid), base $(state_field base))"
  echo "  connect: kata ssh        status: kata vm --status        stop: kata vm --stop"
  exit 1
fi
if [[ -e "$VM_STATE_FILE" ]]; then clear_stale_session; fi

[[ -n "$HOME_DIR" ]] || HOME_DIR="$MOUNT_HOME"
[[ -d "$HOME_DIR" ]] || {
  echo "agent home not found: $HOME_DIR"
  echo "  plain tree on this disk:  kata home init"
  echo "  encrypted key:            sudo utils/disk.sh mount"
  echo "                            then MOUNT_HOME=<its @home> in config.local.sh"
  echo "  or for this run only:     kata vm --home PATH"
  exit 1
}
[[ $EUID -eq 0 ]] || {
  echo "run as root (sudo)"
  exit 1
}

if [[ "$SSH_MODE" == true ]]; then
  [[ "$INTERNET_ENABLED" == true ]] || {
    echo "--ssh needs the bridge NIC — not compatible with --no-int"
    exit 1
  }
  command -v ssh >/dev/null || {
    echo "--ssh needs an ssh client (install openssh)"
    exit 1
  }
  command -v setsid >/dev/null || {
    echo "--ssh needs setsid (util-linux) to detach the session"
    exit 1
  }
fi

# Writes into your real home are refused; --ro is exempt (lib.sh).
refuse_under_home "$HOME_DIR"
for p in "${EXTRA_RW[@]}"; do refuse_under_home "$p" --rw; done

# Only the paths about to be used are checked, so `--home /tmp/x` demands nothing.
require_storage "$HOME_DIR" "${EXTRA_RO[@]}" "${EXTRA_RW[@]}"

# --- Base resolution ---------------------------------------------------------
# Never agent-writable: bases are parsed as root (threat: base-poisoning).
[[ -n "$FROM_NAME" ]] || FROM_NAME="$VM_BASE_NAME"
require_storage "$VM_BASES_DIR"
mkdir -p "$VM_BASES_DIR"

BACKING="$(base_img "$FROM_NAME")"
[[ -f "$BACKING" ]] || {
  echo "base image missing: $BACKING"
  echo
  echo "  bases in ${VM_BASES_DIR}:"
  find "$VM_BASES_DIR" -maxdepth 1 -name '*.qcow2' -printf '    %f\n' 2>/dev/null | sed 's/\.qcow2$//' | grep . ||
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

# Arch: /usr/lib; Debian/Fedora: /usr/libexec.
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
# The image and the host are each fine; the PAIR is wrong. Empty on either side
# is unknown, never a mismatch.
if [[ "$INTERNET_ENABLED" == true ]]; then
  BASE_CA="$(base_ca "$FROM_NAME")"
  HOST_CA="$(ca_fingerprint)"
  if [[ -n "$BASE_CA" && -n "$HOST_CA" && "$BASE_CA" != "$HOST_CA" ]]; then
    gate "$FORCE" "base '${FROM_NAME}' trusts a different mitmproxy CA than the one running" <<EOF
base: ${BASE_CA}   host: ${HOST_CA}

net-up.sh regenerates the CA whenever ${PROXY_CA_PEM} is missing, and the
image's trust store is baked in at build time. Every TLS request in the guest
would fail certificate validation — a symptom that names the proxy rather than
the image.

fix: kata build-base          (rebuild against the current CA)
     kata vm --force …        (boot anyway; expect TLS errors)
EOF
  fi
fi

# Only refused with --to: that is the case that writes the staleness down.
if [[ -n "$TO_NAME" ]] && base_stale "$FROM_NAME"; then
  # Force-neutral summary: gate() prefixes error:/warning:.
  gate "$FORCE" "--to ${TO_NAME} would bake on top of a stale base" <<EOF
$(base_describe "$FROM_NAME")

Baking on top of it carries the old parent forward, and nothing afterwards shows
that the result is built on an image you have already replaced.

fix: kata vm --from ${VM_BASE_NAME} --to ${TO_NAME} …   (rebuild on current)
     kata vm --force …                                 (bake anyway)
EOF
fi

# --- Egress preflight ------------------------------------------------------
# Three checks, none subsumes another: the bridge (the NIC's link), agent_vm
# (the gate the guest's packets are matched in), and proxy_state (something
# ANSWERS — structure checks were all green while the proxy hung). proxy_state
# comes from the host, so it cannot replace the nft check.
if [[ "$INTERNET_ENABLED" == true ]]; then
  ip link show "$BRIDGE" &>/dev/null || refuse "bridge ${BRIDGE} is missing" <<EOF
The guest's only NIC has nothing to attach to.
fix: kata up
EOF

  nft list table inet agent_vm &>/dev/null || refuse "nft table inet agent_vm is missing" <<EOF
That table IS the session gate: the guest's packets arrive over ${BRIDGE} and
are matched there. Without it they hit the terminal drop and nothing works.
fix: kata up
EOF

  PSTATE="$(proxy_state)"
  case "$PSTATE" in
  ok) : ;;
  down) refuse "nothing is listening on ${HOST_IP}:${PROXY_PORT}" <<EOF
The guest's only route out is down. Every request in the session would hang.
fix: kata up
EOF
    ;;
  wedged) refuse "mitmproxy on ${HOST_IP}:${PROXY_PORT} accepts connections but does not answer" <<EOF
This reads as a broken allowlist and is not one (knowledge/egress.md, IPv6).
fix: kata down && kata up
EOF
    ;;
  # Not 403 = not our addon. Booting against it would mean unfiltered egress
  # with every structural check green.
  *) refuse "the proxy on ${HOST_IP}:${PROXY_PORT} answered ${PSTATE}, expected 403" <<EOF
Something is listening there, but it did not deny an unresolvable host — so it
is not the allowlist addon, and the sandbox would have UNFILTERED egress.
fix: kata down && kata up   (then: podman logs agent-proxy)
EOF
    ;;
  esac
fi

# --- GPU passthrough (VFIO) -----------------------------------------------
# VFIO opens groups, not devices: every device in the GPU's IOMMU group must be
# on vfio-pci and passed together. gpu-mode.sh binds at boot; here we verify.
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
      echo "      kata gpu-mode sandbox && sudo reboot"
      echo "  Check the current state any time with: kata gpu-mode status"
      exit 1
    fi
    # romfile= (empty) is REQUIRED with -vga none: the GPU becomes the only VGA
    # device, SeaBIOS tries to execute its (incomplete, laptop) option ROM and
    # hangs. Symptom: live qemu, zero-byte serial.log (knowledge/gpu.md).
    # GPU_ROMFILE applies to the display function only, never the audio one.
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
QEMU_CLEAN=0 # 1 only after qemu exits 0 (clean guest poweroff)
QEMU_PID=""
HANDED_OFF=0 # 1 once vm-supervise.sh owns the session

cleanup() {
  set +e
  # Detached: the supervisor owns teardown. Running it here would pull the
  # virtiofsds and the overlay out from under a healthy guest.
  [[ $HANDED_OFF -eq 1 ]] && return 0
  if [[ -n "$QEMU_PID" ]] && pid_alive "$QEMU_PID"; then
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
# Signals exit without QEMU_CLEAN, so an interrupted session is never baked.
# HUP too: bash killed by an untrapped signal skips its EXIT trap, and a closed
# terminal would leave the state file, rundir and overlay behind.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Same size as build-base grew the base to, or partition table and disk disagree.
qemu-img create -F qcow2 -b "$BACKING" -f qcow2 "$OVERLAY" "$VM_DISK_SIZE" >/dev/null

# --- virtiofsd per mount --------------------------------------------------
VFS_ARGS=()
start_vfs() {
  local idx="$1" dir="$2" tag="$3" ro="$4"
  local sock="${RUN_DIR}/vfs${idx}.sock"
  local extra=()
  [[ "$ro" == true ]] && extra+=(--readonly)
  # Ignored HUP is inherited across fork+exec, so a detached session keeps its
  # home when the launching terminal closes.
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

# Tag `workspace` is what existing bases mount at /home/agent; keep the name.
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
# A tap on the bridge, never SLIRP (threat: no-slirp).
NET_ARGS=(-nic none)
if [[ "$INTERNET_ENABLED" == true ]]; then
  NET_ARGS=(
    -netdev "bridge,id=n0,br=${BRIDGE}"
    -device "virtio-net-pci,netdev=n0,romfile="
  )
fi

# threat: qemu-uid-drop. Every privileged resource (/dev/kvm, the tap, the
# virtiofsd sockets, the disks) is opened during init as root; then qemu drops to
# the agent uid, so an escape lands where agent_isolate already fences it. This
# script stays root for cleanup. Needs qemu >= 8.0; refuses to run qemu as root
# unless ALLOW_QEMU_ROOT=1.
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

# World-readable, paths only. A state file with no live pid counts as a leftover,
# so `pid` is filled in once qemu runs. Best-effort: no jq costs --status only.
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
  # Re-baking is normal, but it silently destroys what is there (often 15G+).
  if [[ -e "$(base_img "$TO_NAME")" ]]; then
    echo "         REPLACES the existing $(base_describe "$TO_NAME") ($(du -h "$(base_img "$TO_NAME")" 2>/dev/null | cut -f1))"
  fi
fi
echo "    extra ro=${#EXTRA_RO[@]} rw=${#EXTRA_RW[@]}"
[[ "$INTERNET_ENABLED" == true && "$SSH_MODE" != true ]] && echo "    tip: for nvim/TUIs, re-run with --ssh (this serial console is poor for them)"

# VFIO pins all guest RAM and charges it to RLIMIT_MEMLOCK. At init qemu is root
# (CAP_IPC_LOCK, limit ignored, but locked_vm is still charged); after the uid
# drop, the next DMA map — SeaBIOS shadowing 0xc0000 — is checked against the
# inherited limit (8M) and fails: "vfio: DMA mapping failed", qemu aborts.
# Bounded at RAM + 1G, not unlimited, so an escaped qemu cannot pin the host.
if [[ "$GPU_MODE" == true ]]; then
  ulimit -l $(($(mem_kib "$MEM") + 1048576))
fi

# share=on: virtiofs needs it. prealloc with --gpu moves page faults to boot.
MEM_OBJ="memory-backend-memfd,id=mem,size=${MEM},share=on"
[[ "$GPU_MODE" == true ]] && MEM_OBJ="${MEM_OBJ},prealloc=on"

# threat: qemu-device-surface. `-display none` removes the display BACKEND, not
# the stdvga DEVICE — `-vga none` removes the device (a VGA bug in
# knowledge/vm-escape-2026-08.md). The machine options live in config.sh.
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
  # The guest outlives this command: vm-supervise.sh, under setsid, owns qemu and
  # the teardown. Otherwise closing this terminal would SIGHUP the guest and the
  # virtiofsds (its home) with it.
  SERIAL_LOG="${RUN_DIR}/serial.log"
  SUP_LOG="${RUN_DIR}/supervise.log"
  QEMU_BASE+=(
    -display none
    -serial "file:${SERIAL_LOG}"
    # For `kata vm --stop`: the ACPI button without the guest's password.
    -monitor "unix:${RUN_DIR}/monitor.sock,server=on,wait=off"
  )

  # `declare -p` hands the argv over losslessly; the rundir is root-owned.
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
    # The supervisor removes the state file when qemu is gone: the boot died.
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
# qemu owns the terminal, so there is no `$!`: the recorded pid is this script,
# alive exactly as long as the session. Hence --stop refuses to signal it.
write_state "$$" true
"${QEMU_BASE[@]}" -nographic -serial mon:stdio || QEMU_RC=$?

# Only a clean guest poweroff (rc 0) may be baked.
if [[ $QEMU_RC -eq 0 ]]; then
  QEMU_CLEAN=1
else
  echo "[!] qemu exited ${QEMU_RC} — session not eligible for --to bake"
fi
