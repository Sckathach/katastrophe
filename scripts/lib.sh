# lib.sh — shared functions. Sourced by config.sh; never source it directly.
#
# STYLE RULE: never end a function or a top-level loop with a bare
# `[[ … ]] && …`. When the test is false the construct returns non-zero, and
# under `set -e` that kills the caller at `source config.sh`, silently. Use an
# if-block or an explicit `return 0`.

# --- Report output ----------------------------------------------------------
# For the report commands (status, bases, doctor). Colour only on a terminal.
if [[ -t 1 ]]; then
  _C_OK=$'\033[32m' _C_WARN=$'\033[33m' _C_ERR=$'\033[31m' _C_INFO=$'\033[36m' _C_OFF=$'\033[0m'
else
  _C_OK="" _C_WARN="" _C_ERR="" _C_INFO="" _C_OFF=""
fi
ok() { printf '%s[ok]%s %s\n' "$_C_OK" "$_C_OFF" "$*"; }
warn() { printf '%s[--]%s %s\n' "$_C_WARN" "$_C_OFF" "$*"; }
err() { printf '%s[!!]%s %s\n' "$_C_ERR" "$_C_OFF" "$*"; }
info() { printf '%s[..]%s %s\n' "$_C_INFO" "$_C_OFF" "$*"; }

# LC_ALL=C: a French locale prints 3.1G as "3,1G".
human_size() { LC_ALL=C numfmt --to=iec --format='%.1f' "${1:-0}" 2>/dev/null || echo "?"; }

# --- Refusals -------------------------------------------------------------
# One shape for every guard, on stderr:
#
#   error: <one greppable line>
#     <indented detail, from the heredoc on stdin>
#     fix: <the command>
#
# gate() also handles --force, so a guard is one call site, not two bodies that
# drift. The `-t 0` test matters: a caller that forgets the heredoc would
# otherwise block reading the terminal, which looks exactly like a qemu hang.
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
# Expected owner of a storage root — the ownership CLASS from the security
# model. Empty = don't care. $HOST_USER is empty outside sudo.
_storage_root_owner() {
  case "$1" in
  "$MOUNT_HOME") echo "$AGENT_USER" ;;
  "$VM_BASES_DIR" | "$SHARED_STORAGE_DIR") echo "${HOST_USER:-}" ;;
  *) echo "" ;;
  esac
}

# Refuse a storage tree that is not ready. The data-loss case: an unmounted
# mountpoint is an ordinary root-owned directory, and a ROOT write there
# succeeds on the root filesystem, then vanishes under the next mount.
#
# The test is ownership, not `mountpoint -q`: it needs no knowledge of the
# medium, and it asserts the invariant itself (a mounted @home is agent-owned,
# the bare mountpoint under it is not).
#
# Args: paths about to be used; only the roots they fall under are checked, so
# `--home /tmp/scratch` demands nothing. No args = every root.
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

  sudo utils/disk.sh mount   # if this home lives on the encrypted key
  kata home init             # if it is a plain tree on the host disk
  kata vm --home PATH        # or point somewhere else for this run
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
# Never `kill -0`: qemu runs as the agent uid, so kill(2) from your uid is EPERM
# and a live session reads as dead — while root, where it succeeds, disagrees.
# /proc has no such asymmetry. It cannot see pid reuse; callers pair it with the
# session's rundir.
pid_alive() {
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/${p}" ]]
}

# --- Session state file ----------------------------------------------------
# The one reader of $VM_STATE_FILE. Two readers of one file eventually disagree.
#
# Null-test explicitly, not `.[$k] // empty`: jq's `//` also fires on `false`,
# so `gpu: false` would read back as "" (unknown).
state_field() {
  [[ -r "$VM_STATE_FILE" ]] || return 0
  jq -r --arg k "$1" 'if .[$k] == null then empty else .[$k] end' "$VM_STATE_FILE" 2>/dev/null || true
}

# Running = the pid is alive. A state file whose qemu is gone is a leftover and
# must never block the next launch. The rundir check guards against pid reuse:
# the session's own teardown removes it.
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
# Both unprivileged: `kata status` must never prompt.

listens() { # $1=ip $2=port
  ss -lnt "sport = :${2}" 2>/dev/null | grep -q "${1}:${2}"
}

# Ask the proxy for an unresolvable host. The addon answers 403 before any
# upstream connection, so this works offline. Not `podman container exists`: a
# wedged mitmproxy keeps its container AND its socket while answering nothing.
#
# It does NOT prove the guest's path: this request comes from the host and never
# crosses `agent_vm input`. Only utils/audit-egress.sh, in the guest, proves that.
proxy_state() { # -> ok | wedged | down | <http code>
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
    -x "http://${HOST_IP}:${PROXY_PORT}" http://kata-status.invalid/ 2>/dev/null || true)"
  case "$code" in
  403) echo ok ;;
  # curl says 000 for both "refused" and "connected then silent"; ss tells them apart.
  000 | "") if listens "$HOST_IP" "$PROXY_PORT"; then echo wedged; else echo down; fi ;;
  *) echo "$code" ;;
  esac
}

# The profile the RUNNING gate enforces, from its 403 body — not the configured
# one, which differs until you re-run `kata up`. Empty = not answering.
proxy_profile() {
  curl -s --max-time 6 -x "http://${HOST_IP}:${PROXY_PORT}" \
    http://kata-status.invalid/ 2>/dev/null |
    sed -n 's/^kata: allowlist\[\([A-Za-z0-9_-]\{1,\}\)\].*/\1/p' | head -1
}

# --- Warm-base metadata ----------------------------------------------------
# A base is <name>.qcow2 + a <name>.json sidecar:
#   name, version (++ per write), created (UTC), origin (build|bake),
#   parent {name, version at bake time} or null, gpu, ca, history (last 10)
# jq is needed to write it. A missing sidecar is never fatal: the base just
# reads as unversioned.
base_img() { echo "${VM_BASES_DIR}/${1}.qcow2"; }
base_meta_path() { echo "${VM_BASES_DIR}/${1}.json"; }

# Fingerprint of the proxy CA, from the world-readable copy first so this needs
# no root. Empty = unknown (no CA yet); callers must never treat that as drift.
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

# The CA a base was built to trust, or empty when unknown.
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

# Is this base built on a parent that has since moved on?
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

# Current version of a base, or 0 when there is no readable sidecar.
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
# Records the parent's version AT BAKE TIME: that snapshot is what makes a
# stale child detectable later. Written as root by --to, so handed back to you.
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
  # The CA this image trusts: baked in by build-base, live during a bake. If the
  # host CA is ever regenerated, this is the only thing that shows the drift.
  ca="$(ca_fingerprint)"

  local prev='[]'
  if [[ -r "$meta" ]]; then
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

# save_base <overlay> <name> <parent-name|""> <gpu: true|false>
# Flatten a session overlay into a standalone base. Shared by vm.sh (attached)
# and vm-supervise.sh (detached) so both bake identically. Temp + mv, so an
# interrupted convert never leaves a half-written base.
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

# One HMP command to a qemu monitor socket (`kata vm --stop` presses the ACPI
# power button, so the guest shuts down cleanly and stays eligible for a bake).
# socat, nc -U or python3 — none worth a hard dependency.
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

# "cuda v2 ← base v1" for banners. No parent → "(built)".
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
# For --home and every --rw mount: writes into your real home. --ro is exempt on
# purpose — read-only ingress of a real project is the intended workflow, and an
# escape lands as the agent uid, which agent_isolate fences.
# FORBIDDEN_WORKSPACE_PREFIX= (empty) disables it.
refuse_under_home() {
  local path="$1" flag="${2:---workspace}"
  [[ -n "${FORBIDDEN_WORKSPACE_PREFIX:-}" ]] || return 0
  case "$(readlink -f -- "$path")" in
  "$FORBIDDEN_WORKSPACE_PREFIX" | "$FORBIDDEN_WORKSPACE_PREFIX"/*)
    echo "refusing $flag under $FORBIDDEN_WORKSPACE_PREFIX: $path" >&2
    echo "  copy it outside your home first (the agent uid can't traverse it)," >&2
    echo "  or export FORBIDDEN_WORKSPACE_PREFIX= to bypass." >&2
    exit 1
    ;;
  esac
}

# --- GPU helpers (vm.sh and gpu-mode.sh) ----------------------------------
# These return 0 even with no GPU: callers do `X="$(gpu_addr)"` under `set -e`
# and report the absence themselves.

# $GPU_PCI_ADDR, else the first NVIDIA VGA/3D device, else nothing.
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

# Every PCI address in $1's IOMMU group. VFIO binds whole groups, so all of them
# go to vfio-pci together (here: the GPU + its HDA function). Returns 1 only when
# the group cannot be read at all (no IOMMU).
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

# Driver bound to a PCI device; empty if none.
pci_driver() {
  basename "$(readlink -f "/sys/bus/pci/devices/${1}/driver" 2>/dev/null)" 2>/dev/null || true
}

# --- Misc -----------------------------------------------------------------
# A qemu `-m` size in KiB, the unit `ulimit -l` speaks (the VFIO memlock in
# vm.sh). Bare number = MiB, like qemu. Fails loudly rather than guess: a wrong
# value becomes a qemu abort mid-firmware.
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
