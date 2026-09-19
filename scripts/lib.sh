# lib.sh — shared shell FUNCTIONS for the agent sandbox scripts.
#
# Sourced by config.sh (which sources it before any of its own logic runs), so
# scripts get these for free from `source ../config.sh` and never source this
# file directly. The split is readability only: config.sh is the declarations
# you scan to answer "what is the port / path / uid", this is the behaviour
# behind them. Constants live there, never here.
#
# STYLE RULE, learned the hard way: never end a function or a top-level loop
# with a bare `[[ … ]] && …`. When the test is false the whole construct exits
# non-zero, and under the `set -e` every script uses that kills the caller at
# `source config.sh` — silently, before anything is printed. Use an if-block or
# an explicit `return 0`. (gpu_addr/pci_driver return 0 even when there is no
# GPU for the same reason: callers do `X="$(gpu_addr)"` under `set -e` and need
# to report the absence themselves.)

# --- Refusals -------------------------------------------------------------
# ONE shape for every guard, because the house rule is that a refusal must print
# the command that fixes it, and a rule only survives if it is cheap to obey:
#
#   error: <one line saying what is wrong>
#     <indented detail — what would happen if we continued>
#     fix: <the command>
#
# That is cargo/rustc/git's convention, and it earns its keep for boring reasons:
# the summary is greppable, and it goes to STDERR. The hand-rolled `echo` blocks
# this replaces went to stdout, so a refusal was indistinguishable from output
# and `2>/dev/null` hid nothing.
#
# gate() also handles the --force case, so a guard is one call site rather than
# an if/else with the body written twice — which is how the two halves drift
# apart and the forced path stops explaining itself.
#
# Body is read from stdin (heredoc). The `-t 0` test is load-bearing: without it
# a caller that forgets the heredoc blocks forever reading the terminal, which
# looks exactly like a hang in qemu.
gate() { # gate <forced: true|false> <summary>   [body on stdin]
  local forced="${1:-false}" summary="$2"
  if [[ "$forced" == true ]]; then
    printf 'warning: %s\n' "$summary" >&2
    if [[ ! -t 0 ]]; then sed 's/^/  /' >&2; fi
    printf '  --force given: proceeding anyway.\n' >&2
    return 0
  fi
  printf 'error: %s\n' "$summary" >&2
  if [[ ! -t 0 ]]; then sed 's/^/  /' >&2; fi
  exit 1
}

refuse() { gate false "$1"; } # the common case: no override exists

# --- Storage readiness ----------------------------------------------------
# There is one home ($MOUNT_HOME) and one bases dir ($VM_BASES_DIR), both plain
# paths from config.sh. This used to be ~120 lines resolving two whole trees from
# a KATA_STORAGE mode, plus the pin machinery that let config.local.sh override
# the result, plus a banner announcing which tree had won. All of it deleted
# 2026-09-13 with the mode itself; see the storage block in config.sh.

# Expected owner of a storage root, as a username. Empty = don't care.
# This is the ownership CLASS from the security model, not a cosmetic detail:
# the agent home must be agent-owned (it is the one rw tree the agent gets), and
# the bases dir + shared inputs must be YOURS (vm.sh parses base qcow2s as root,
# threat: base-poisoning). $HOST_USER is empty outside sudo, hence the fallbacks.
_storage_root_owner() {
  case "$1" in
  "$MOUNT_HOME") echo "$AGENT_USER" ;;
  "$VM_BASES_DIR" | "$SHARED_STORAGE_DIR") echo "${HOST_USER:-}" ;;
  *) echo "" ;;
  esac
}

# Refuse to touch a storage tree that isn't ready, instead of guessing.
#
# THE FAILURE THIS PREVENTS, and it is a data-loss one: a mountpoint is an
# ordinary directory when nothing is mounted on it. $MOUNT_HOME pointed at
# /mnt/agent-home with the key unplugged is a bare root-owned dir. An agent-uid
# write there fails loudly (annoying, but safe). A ROOT write SUCCEEDS — it lands
# on the root filesystem, in a directory that disappears under the mount the next
# time the key goes in. Silent, and it eats the data.
#
# The check is OWNERSHIP, not `mountpoint -q`. The old version had to ask "are we
# in usb mode?" to decide which test applied, and that was the last thing in
# lib.sh that knew what a USB was. Ownership needs no such question and is the
# stronger claim anyway: a mounted @home is agent:agent, the bare mountpoint
# under it is root:root, and a local /home/agent that `disk.sh local-init` never
# created is either missing or root-owned too. One test, every medium, and what it
# asserts is the invariant we actually care about rather than a proxy for it.
#
# Args: paths about to be used. Only roots those paths actually fall under are
# checked, so `--home /tmp/scratch` demands nothing. With no args, every root is.
require_storage() {
  local roots=("$MOUNT_HOME" "$SHARED_STORAGE_DIR" "$VM_BASES_DIR")
  local paths=("$@") p root bad=()
  ((${#paths[@]})) || paths=("${roots[@]}")
  for p in "${paths[@]}"; do
    [[ -n "$p" ]] || continue
    for root in "${roots[@]}"; do
      [[ -n "$root" ]] || continue
      case "$p" in
      "$root" | "$root"/*) bad+=("$(_storage_root_check "$root")") ;;
      esac
    done
  done

  local uniq
  uniq="$(printf '%s\n' "${bad[@]}" | grep -v '^$' | sort -u || true)"
  [[ -n "$uniq" ]] || return 0

  cat >&2 <<EOF
storage: refusing to continue.

${uniq}

Writing to a directory that is only *standing in* for a mount is how data
disappears: as root it lands on your root filesystem and then vanishes under the
mount the next time it happens. So this is a refusal, not a warning.

  sudo kata disk mount        # if this home lives on the encrypted key
  sudo kata disk local-init   # if it is a plain tree on the host disk
  kata vm --home PATH         # or point somewhere else for this run
EOF
  exit 1
}

# One diagnostic line for a root, or empty when it is fine.
_storage_root_check() {
  local root="$1" want owner
  if [[ ! -d "$root" ]]; then
    echo "  ${root} — does not exist"
    return 0
  fi
  want="$(_storage_root_owner "$root")"
  [[ -n "$want" ]] || return 0
  owner="$(stat -c %U "$root" 2>/dev/null || echo '?')"
  if [[ "$owner" != "$want" ]]; then
    echo "  ${root} — owned by '${owner}', expected '${want}'$(mountpoint -q "$root" || echo ' (nothing mounted here)')"
  fi
  return 0
}

# --- Process liveness ------------------------------------------------------
# Is PID alive? NOT `kill -0`, and that distinction cost a whole session:
# qemu drops to the agent uid (`-run-with user=agent`), so kill(2) from YOUR
# uid returns EPERM and the process reads as dead. `kata ssh` then answered "no
# session running" about a guest that was plainly up, while the very next
# `kata vm` — running as root, where kill -0 succeeds — refused to start a
# second one. Two commands, opposite answers, same state file.
#
# /proc has no such asymmetry: the entry exists for every live process whatever
# its owner (this is Linux-only, like everything else here). Pid reuse is the
# one thing it can't see; callers that care pair it with a rundir that the
# session's own teardown removes.
pid_alive() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/${p}" ]]
}

# --- Session state file ----------------------------------------------------
# $VM_STATE_FILE is the session registry: world-readable, paths and scalars
# only, so `kata vm --status` needs no root.
#
# NOT `.[$k] // empty`, which is the obvious spelling and is wrong for exactly
# the fields where being wrong matters. jq's `//` fires on `false` as well as on
# `null`, so `gpu: false` came out as the EMPTY STRING and `--status` printed
# `gpu=` on a CPU session — a present-and-false field rendering as *unknown*,
# which is the same failure shape as a check that says "can't tell" when it
# means "fine". Test for null explicitly.
#
# This lived in BOTH kata and vm.sh until 2026-09-13, and the copies diverged
# the moment one of them was fixed — `kata vm --status` said `gpu=false` while
# `kata status` still said `gpu=`. That is the whole argument for one home here:
# a probe duplicated across callers is a probe that will eventually disagree
# with itself about the same file.
state_field() {
  [[ -r "$VM_STATE_FILE" ]] || return 0
  jq -r --arg k "$1" 'if .[$k] == null then empty else .[$k] end' "$VM_STATE_FILE" 2>/dev/null || true
}

# Is a session genuinely running, and what is its pid?
#
# "Running" means THAT PID IS ALIVE — a state file whose qemu is gone is a
# leftover (killed terminal, host crash) and must never make the next launch
# refuse. The rundir check is the pid-reuse guard: the session's own teardown
# removes it, so a recycled pid pointing at an unrelated process needs a stale
# rundir to fool us as well.
#
# These two were the LAST of the state-file readers still living in their
# callers — `session_pid` in kata, `session_alive` in vm.sh, same question asked
# two slightly different ways. tests/guards.sh called session_pid and got
# "command not found", which is the mild version of the failure; the bad version
# is the two answering differently about the same session.
session_alive() {
  local p rd
  p="$(state_field pid)"
  pid_alive "$p" || return 1
  rd="$(state_field rundir)"
  if [[ -n "$rd" ]]; then [[ -d "$rd" ]] || return 1; fi
  return 0
}

session_pid() {
  session_alive || return 1
  state_field pid
}

# --- Functional probes -----------------------------------------------------
# Both work UNPRIVILEGED, which is the design rule for `kata status` and the
# reason the old dashboard's sudo problem does not exist any more.

listens() { # $1=ip $2=port
  ss -lnt "sport = :${2}" 2>/dev/null | grep -q "${1}:${2}"
}

# Ask the proxy for a host that cannot resolve. A healthy mitmproxy running our
# addon answers 403 from the allowlist BEFORE it opens any upstream connection,
# so this generates no external traffic and works offline.
#
# Deliberately not `podman container exists`: a wedged mitmproxy keeps its
# container AND its listening socket — it completes the TCP handshake and then
# answers nothing — so both of those report healthy while the sandbox has no
# egress at all. That exact false positive cost an evening (the IPv6 gotcha).
#
# WHAT IT DOES NOT PROVE, stated because an earlier comment here overclaimed it:
# this request comes from the HOST, to a local address, so it never traverses
# `agent_vm input` and says nothing about whether the *guest* can reach the
# proxy. It proves the proxy process is alive and the allowlist addon is loaded.
# The guest-side path needs the nft table to exist (checked separately) and is
# only really proven from inside a guest — that is what audit-egress.sh is for.
proxy_state() { # -> ok | wedged | down | <http code>
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
    -x "http://${HOST_IP}:${PROXY_PORT}" http://kata-status.invalid/ 2>/dev/null || true)"
  case "$code" in
  403) echo ok ;;
  # curl reports 000 for both "refused" and "connected then silent"; ss tells
  # the two apart.
  000 | "") if listens "$HOST_IP" "$PROXY_PORT"; then echo wedged; else echo down; fi ;;
  *) echo "$code" ;;
  esac
}

# Which allowlist profile the RUNNING gate enforces, read out of the 403 body
# (`kata: allowlist[swe]: …`). Empty when the proxy is not answering.
#
# Deliberately not `echo $ALLOWLIST_PROFILE`: that is the CONFIGURED value, and
# the interesting failure is exactly when the two differ — you edited
# config.local.sh, or ran `kata up --profile research` yesterday, and the
# container has been enforcing something else ever since. Same principle as the
# CA fingerprint in base sidecars: ask the thing that is running, not the thing
# that describes it.
proxy_profile() { # -> profile name, or "" if the proxy is not answering
  curl -s --max-time 6 -x "http://${HOST_IP}:${PROXY_PORT}" \
    http://kata-status.invalid/ 2>/dev/null |
    sed -n 's/^kata: allowlist\[\([A-Za-z0-9_-]\{1,\}\)\].*/\1/p' | head -1
}

# --- Warm-base metadata ----------------------------------------------------
# A base is $VM_BASES_DIR/<name>.qcow2 plus a <name>.json sidecar. The sidecar
# answers the question the file alone cannot: "is this cuda base built from the
# CURRENT blank base, or from the one I replaced last week?" — which is exactly
# the confusion that made a months-old image look authoritative.
#
# Schema (see `kata bases` for the reader):
#   name, version (int, ++ on every write), created (UTC), origin (build|bake),
#   parent {name, version} or null, gpu (bool), history [previous records]
# jq is required to WRITE it; without jq the image is still perfectly usable,
# it just shows up as version-unknown. Never make a missing sidecar fatal —
# bases baked before this existed have none.
base_img() { echo "${VM_BASES_DIR}/${1}.qcow2"; }
base_meta_path() { echo "${VM_BASES_DIR}/${1}.json"; }

# Fingerprint of the CA the guest images are built to trust. Empty when there is
# no CA on this host yet (`kata up` has never run) — callers must treat empty as
# "unknown", never as "mismatch".
#
# Reads the WORLD-READABLE copy first ($PROXY_CA_CERT_PUB): $PROXY_CA_DIR is
# 0700 owned by uid 1000 for the container, so hashing the original would make
# this a root-only probe for no reason. Both files are the same public
# certificate; the private key is in $PROXY_CA_PEM and is never touched here.
ca_fingerprint() {
  local f
  for f in "${PROXY_CA_CERT_PUB:-}" "${PROXY_CA_CERT:-}"; do
    if [[ -n "$f" && -r "$f" ]]; then
      sha256sum "$f" 2>/dev/null | cut -c1-16
      return 0
    fi
  done
  echo ""
  return 0
}

# The CA fingerprint recorded in a base's sidecar, or empty when the base
# predates the field (every base baked before 2026-09-13).
base_ca() {
  local f
  f="$(base_meta_path "$1")"
  if [[ -r "$f" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.ca // ""' "$f" 2>/dev/null || echo ""
  else
    echo ""
  fi
  return 0
}

# Is this base built on a parent that has since moved on? The condition behind
# the [STALE] marker in `kata bases`, factored out so a guard can refuse on it
# rather than only printing it.
base_stale() { # -> 0 = stale, 1 = current / unknown
  local name="$1" f pn pv cur
  f="$(base_meta_path "$name")"
  [[ -r "$f" ]] && command -v jq >/dev/null 2>&1 || return 1
  pn="$(jq -r '.parent.name // ""' "$f" 2>/dev/null)"
  pv="$(jq -r '.parent.version // 0' "$f" 2>/dev/null)"
  [[ -n "$pn" ]] || return 1
  cur="$(base_version "$pn")"
  [[ "$cur" != 0 && "$cur" -gt "$pv" ]]
}

# Current version of a base, or 0 when there is no (readable) sidecar.
base_version() {
  local f
  f="$(base_meta_path "$1")"
  if [[ -r "$f" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.version // 0' "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# base_meta_write <name> <origin: build|bake> <parent-name|""> <gpu: true|false>
# Bumps the version, records the parent's version AT BAKE TIME (that snapshot is
# the point — it stays true after the parent moves on), and pushes the previous
# record onto history. Ownership matches the qcow2: the bases dir is you-owned
# 0700 in both storage modes, and `--to` runs as root, so hand both files back
# to $HOST_USER or `kata bases` can't read what root just wrote.
base_meta_write() {
  local name="$1" origin="$2" parent="$3" gpu="${4:-false}"
  local meta ver pver created ca
  meta="$(base_meta_path "$name")"
  if ! command -v jq >/dev/null 2>&1; then
    echo "[!] jq missing — base '${name}' saved without version metadata" >&2
    return 0
  fi
  ver=$(($(base_version "$name") + 1))
  pver=0
  if [[ -n "$parent" ]]; then pver="$(base_version "$parent")"; fi
  created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Which mitmproxy CA this image trusts. Correct for BOTH origins for the same
  # reason: build-base.sh bakes $PROXY_CA_CERT into the image's trust store, and
  # a bake freezes a guest that has been running against the CA live right now.
  # net-up.sh regenerates the CA whenever $PROXY_CA_PEM is missing (a reinstall,
  # an /etc wipe), and the only thing it does about the images that still trust
  # the old one is print a suggestion — so without this field the drift is
  # invisible until the guest reports TLS errors that read as a proxy bug.
  ca="$(ca_fingerprint)"

  local prev='[]'
  if [[ -r "$meta" ]]; then
    # Keep the last 9 + the one we're about to supersede = 10 records.
    prev="$(jq -c '[(.history // [])[], (del(.history))] | .[-9:]' "$meta" 2>/dev/null || echo '[]')"
  fi
  jq -n \
    --arg name "$name" --arg created "$created" --arg origin "$origin" \
    --arg parent "$parent" --argjson pver "$pver" --arg ca "$ca" \
    --argjson ver "$ver" --argjson gpu "$gpu" --argjson hist "$prev" \
    '{name: $name, version: $ver, created: $created, origin: $origin,
      parent: (if $parent == "" then null else {name: $parent, version: $pver} end),
      gpu: $gpu, ca: $ca, history: $hist}' >"${meta}.tmp" &&
    mv -f "${meta}.tmp" "$meta"

  if [[ -n "${HOST_USER:-}" ]] && [[ $EUID -eq 0 ]]; then
    chown "${HOST_USER}:${HOST_USER}" "$meta" 2>/dev/null || true
  fi
  chmod 0644 "$meta" 2>/dev/null || true
  return 0
}

# Flatten a session overlay (+ its backing chain) into a standalone qcow2: the
# new warm base. Shared by vm.sh (attached sessions) and vm-supervise.sh
# (detached ones) so both bake identically — including the metadata bump, which
# is the only record of what this base was built from.
#
# Atomic replace via temp + mv, so an interrupted convert (or re-baking a name
# you are currently booted from) can't leave a half-written base behind.
# Ownership: --to runs as root, but $VM_BASES_DIR is you-owned in both storage
# modes, so hand the result back rather than leaving root-owned files in it.
# save_base <overlay> <name> <parent-name|""> <gpu: true|false>
save_base() {
  local overlay="$1" name="$2" parent="${3:-}" gpu="${4:-false}"
  local dest tmp
  dest="$(base_img "$name")"
  tmp="${dest}.tmp.$$"
  echo "[*] flattening session → base '${name}' (${dest}) ..."
  if qemu-img convert -O qcow2 "$overlay" "$tmp"; then
    mv -f "$tmp" "$dest"
    if [[ -n "${HOST_USER:-}" && $EUID -eq 0 ]]; then
      chown "${HOST_USER}:${HOST_USER}" "$dest" 2>/dev/null || true
    fi
    chmod 0644 "$dest" 2>/dev/null || true
    base_meta_write "$name" bake "$parent" "$gpu"
    echo "[ok] saved base: $(base_describe "$name")"
  else
    rm -f "$tmp"
    echo "[!!] qemu-img convert failed — base '${name}' NOT saved"
  fi
  return 0
}

# Send one HMP command to a qemu monitor unix socket. Used by `kata vm --stop`
# to press the virtual ACPI power button: the guest shuts down properly, qemu
# exits 0, and the session stays eligible for the --to bake. Doing it over ssh
# instead would need the guest password every time.
# Tries socat, then nc -U, then python3 — one of the three is on every host we
# care about, and none of them is worth adding as a hard dependency.
qemu_monitor_send() {
  local sock="$1" cmd="$2"
  if command -v socat >/dev/null 2>&1; then
    printf '%s\n' "$cmd" | socat - "UNIX-CONNECT:${sock}" >/dev/null 2>&1
  elif command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q ' -U'; then
    printf '%s\n' "$cmd" | nc -U -q1 "$sock" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode())
s.close()
' "$sock" "$cmd"
  else
    return 1
  fi
}

# "cuda v2 ← base v1" for the launch banner. Empty parent → "(built)".
base_describe() {
  local name="$1" f v
  f="$(base_meta_path "$name")"
  v="$(base_version "$name")"
  if [[ "$v" == 0 ]]; then
    echo "${name} (unversioned — baked before metadata existed)"
    return 0
  fi
  local pn pv
  pn="$(jq -r '.parent.name // ""' "$f" 2>/dev/null)"
  pv="$(jq -r '.parent.version // 0' "$f" 2>/dev/null)"
  if [[ -z "$pn" ]]; then
    echo "${name} v${v} (built)"
  elif base_stale "$name"; then
    echo "${name} v${v} ← ${pn} v${pv}  [STALE: ${pn} is now v$(base_version "$pn")]"
  else
    echo "${name} v${v} ← ${pn} v${pv}"
  fi
  return 0
}

# --- Foot-gun guard on host paths -----------------------------------------
# Call it for the workspace and every --rw mount, so the guard is applied
# uniformly and early. `--ro` is exempt: virtiofsd runs as root and reads your
# home fine, the guest sees only the mounted subtree, and a real hypervisor
# escape lands as the agent uid — which agent_isolate already fences.
# Read-only ingress of a real project is the intended workflow, not a mistake.
# Args: $1=path, $2=flag label (default --workspace). Export
# FORBIDDEN_WORKSPACE_PREFIX= to bypass.
refuse_under_home() {
  local path="$1" flag="${2:---workspace}"
  [[ -n "${FORBIDDEN_WORKSPACE_PREFIX:-}" ]] || return 0
  case "$(readlink -f -- "$path")" in
  "$FORBIDDEN_WORKSPACE_PREFIX" | "$FORBIDDEN_WORKSPACE_PREFIX"/*)
    echo "refusing $flag under $FORBIDDEN_WORKSPACE_PREFIX: $path" >&2
    echo "  copy it outside your home first (the agent uid can't traverse it)," >&2
    echo "  or export FORBIDDEN_WORKSPACE_PREFIX= to bypass. See CLAUDE.md." >&2
    exit 1
    ;;
  esac
}

# --- GPU helpers (shared by vm.sh and gpu-mode.sh) ------------------------
# Resolve the dGPU's PCI address. Honours $GPU_PCI_ADDR; otherwise takes the
# first NVIDIA VGA/3D device. Prints the address, or nothing if there is none.
# Always returns 0, even when there is no GPU — callers do `X="$(gpu_addr)"`
# under `set -e`, where a non-zero status would abort the script instead of
# letting them report "no NVIDIA GPU found".
gpu_addr() {
  if [[ -n "${GPU_PCI_ADDR:-}" ]]; then
    echo "$GPU_PCI_ADDR"
    return 0
  fi
  local line
  line="$(lspci -Dn 2>/dev/null | awk '$2 ~ /^0(300|302):/ && $3 ~ /^10de:/ {print $1; exit}')"
  if [[ -n "$line" ]]; then echo "$line"; fi
  return 0
}

# Print every PCI address in the same IOMMU group as $1, one per line.
# This is not a nicety: VFIO binds at group granularity, so every function in
# the group must be bound to vfio-pci or the group cannot be opened at all. On
# this laptop the group is {GPU, its HDA audio function}.
# Returns 1 only when the group genuinely can't be read (no IOMMU) — that one
# IS meaningful to callers. Otherwise 0, even if the glob matched nothing.
gpu_group_devices() {
  local addr="$1" grp
  grp="$(basename "$(readlink -f "/sys/bus/pci/devices/${addr}/iommu_group" 2>/dev/null)" 2>/dev/null)"
  [[ -n "$grp" && -d "/sys/kernel/iommu_groups/${grp}/devices" ]] || return 1
  local d
  for d in "/sys/kernel/iommu_groups/${grp}/devices/"*; do
    if [[ -e "$d" ]]; then basename "$d"; fi
  done
  return 0
}

# Driver currently bound to a PCI device (empty if none). Never fails: an
# unbound device is a normal state, not an error.
pci_driver() {
  basename "$(readlink -f "/sys/bus/pci/devices/${1}/driver" 2>/dev/null)" 2>/dev/null || true
}

# --- Misc -----------------------------------------------------------------
# Convert a qemu `-m` size to KiB — the unit `ulimit -l` speaks. Accepts the
# suffixes qemu does (K/M/G/T, case-insensitive); a bare number is MiB, like
# qemu. Used to size RLIMIT_MEMLOCK for VFIO (see the memlock block in vm.sh).
# Fails loudly on anything it can't parse: silently guessing here would turn
# into a qemu abort halfway through the guest's firmware boot.
mem_kib() {
  local s="${1^^}" n unit
  n="${s%[KMGT]}"
  unit="${s:${#n}}"
  [[ "$n" =~ ^[0-9]+$ ]] || {
    echo "mem_kib: cannot parse memory size '$1'" >&2
    return 1
  }
  case "$unit" in
  K) echo "$n" ;;
  "" | M) echo $((n * 1024)) ;;
  G) echo $((n * 1024 * 1024)) ;;
  T) echo $((n * 1024 * 1024 * 1024)) ;;
  esac
}
