#!/usr/bin/env bash
# tests/unit.sh — the pure functions in scripts/lib.sh. No root, no VM, no
# network; runs in under a second, so there is no excuse not to run it.
#
# Invariants covered:
#   B3  a missing sidecar is never fatal
#   B4  an unknown CA is "unknown", never "mismatch"
#   B5  a base whose parent moved on is detected as stale
#   B6  the parent version recorded at bake time does not drift afterwards
#   W1  a storage root with the wrong owner is refused
#   W2  --rw under your home is refused
#   P1  state_field renders a present-and-false field as false, not as empty
#   C1  an environment override beats config.local.sh (the contract every
#       per-run override and half of guards.sh depends on)
#   Q1  the stripped qemu machine options are all still there
#   Q2  both guest-booting scripts consume them, with -nodefaults -vga none
#   Q4  the session path does not link libslirp
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"

# Run a snippet with lib.sh + config.sh loaded, in a subshell so an `exit 1`
# inside a guard is the snippet's exit status and not this script's.
kata_sh() { bash -c "cd '${ROOT}' && source ./config.sh && $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

section "warm-base metadata (B)"

# B3: a base with an image but no sidecar must still describe and still boot.
: >"${TMP}/orphan.qcow2"
allow B3 "a base with no sidecar is still usable" -- \
  kata_sh "VM_BASES_DIR='${TMP}'; d=\"\$(base_describe orphan)\"; [[ \"\$d\" == *unversioned* ]]"

# B4: the guard must not fire when either side is unknown — otherwise every
# base that predates the ca field becomes unbootable. This is the same rule as
# `kata status` saying "unknown (needs sudo)" instead of printing a red row.
allow B4 "an absent CA fingerprint reads as unknown, not as a mismatch" -- \
  kata_sh "VM_BASES_DIR='${TMP}'; [[ -z \"\$(base_ca orphan)\" ]]"

# B5/B6: build parent v1 → child off it → move parent to v2. The child's
# recorded parent version must NOT follow the parent (that snapshot is the whole
# mechanism), and the child must then read as stale.
: >"${TMP}/p.qcow2"
: >"${TMP}/c.qcow2"
setup_stale="VM_BASES_DIR='${TMP}'; HOST_USER=\"\$USER\"
  base_meta_write p build '' false >/dev/null
  base_meta_write c bake p false >/dev/null
  base_meta_write p build '' false >/dev/null"

allow B6 "the parent version in a sidecar is a bake-time snapshot" -- \
  kata_sh "${setup_stale}; [[ \"\$(jq -r '.parent.version' '${TMP}/c.json')\" == 1 ]] &&
           [[ \"\$(base_version p)\" == 2 ]]"

allow B5 "a base whose parent moved on is stale" -- \
  kata_sh "VM_BASES_DIR='${TMP}'; base_stale c"

allow B5 "a base whose parent did not move is not stale (positive control)" -- \
  kata_sh "VM_BASES_DIR='${TMP}'; ! base_stale p"

section "storage + foot-gun guards (W)"

# W1: the failure this prevents is data loss, not a permission error. A
# mountpoint with nothing mounted on it is an ordinary root-owned directory, so
# a ROOT write succeeds onto the root filesystem and vanishes under the next
# mount. Ownership is the invariant; `mountpoint -q` was only a proxy for it.
mkdir -p "${TMP}/notahome"
deny W1 "a storage root with the wrong owner is refused" "owned by|expected" -- \
  kata_sh "MOUNT_HOME='${TMP}/notahome'; require_storage \"\$MOUNT_HOME\""

allow W1 "a path that is not a storage root demands nothing (positive control)" -- \
  kata_sh "require_storage '${TMP}/notahome'"

deny W2 "--rw under your home is refused" "refusing" -- \
  kata_sh "FORBIDDEN_WORKSPACE_PREFIX=\"\$HOME\"; refuse_under_home \"\$HOME/somewhere\" --rw"

allow W2 "the guard is a no-op when the prefix is cleared (documented bypass)" -- \
  kata_sh "FORBIDDEN_WORKSPACE_PREFIX=; refuse_under_home \"\$HOME/somewhere\" --rw"

# W3 (--ro under your home is ALLOWED) is a runtime test in guards.sh: proving a
# call site is absent is not something a unit test can honestly do.

section "state-file reader (P)"

# P1: jq's `//` fires on false as well as null, so `.gpu // empty` turned a
# present-and-false field into the empty string — a CPU session reporting `gpu=`,
# i.e. "cannot tell" when it means "no".
cat >"${TMP}/state.json" <<'JSON'
{"session":"s1","gpu":false,"mem":"32G","to":null}
JSON
is P1 "a false field renders as false" "false" \
  "$(kata_sh "VM_STATE_FILE='${TMP}/state.json'; state_field gpu")"
is P1 "a null field renders as empty" "" \
  "$(kata_sh "VM_STATE_FILE='${TMP}/state.json'; state_field to")"
is P1 "a string field survives" "32G" \
  "$(kata_sh "VM_STATE_FILE='${TMP}/state.json'; state_field mem")"

section "config loading (C)"

# C1 exists because breaking it is INVISIBLE, and it silently disabled a security
# test for a day. config.local.sh is sourced FIRST and every line in it must be
# `VAR="${VAR:-value}"`; a bare `MOUNT_HOME=/mnt/agent-home` still works for
# normal use, so nothing complains — but from then on `env MOUNT_HOME=... kata`
# is ignored, which is what README documents as the way to override, what
# `kata vm --home` tests rely on, and what guards.sh W1 needs to point vm.sh at a
# wrong-owner home. The guard was fine; the test could no longer reach it.
#
# Whatever config.local.sh holds locally, the contract is the same: the
# environment wins. Checked on the values a test would actually override.
for v in MOUNT_HOME VM_BASES_DIR SHARED_STORAGE_DIR PROXY_PORT ALLOWLIST_PROFILE QEMU_MACHINE_OPTS; do
  is C1 "an env override of ${v} beats config.local.sh" "kata-probe" \
    "$(env "${v}=kata-probe" bash -c "cd '${ROOT}' && source ./config.sh && printf '%s' \"\${${v}}\"")"
done

section "emulated device surface (Q)"

# threat: qemu-device-surface. Every emulated device is guest-reachable attack
# surface, and two of these flags exist because of named bugs in
# knowledge/vm-escape-2026-08.md. They are one-word deletions that leave a
# perfectly working guest behind, which is exactly why they need a test: nothing
# else in the system notices if they go, and the regression is silent until
# someone else finds the bug for you.
#
# Text assertions rather than a live qtree, deliberately — this suite is the
# unprivileged one and must not need a VM. The live check is tests/MANUAL.md Q0.
OPTS="$(bash -c "cd '${ROOT}' && source ./config.sh && printf '%s' \"\$QEMU_MACHINE_OPTS\"")"

# Q1: the option list itself. In config.sh rather than in each script, because
# vm.sh and build-base.sh both boot a guest and two copies would drift.
for opt in vmport=off hpet=off smbus=off sata=off usb=off i8042=off graphics=off smm=off; do
  case "$OPTS" in
  *"$opt"*) _pass Q1 "QEMU_MACHINE_OPTS carries ${opt}" ;;
  *) _fail Q1 "QEMU_MACHINE_OPTS carries ${opt}" "got: ${OPTS}" ;;
  esac
done

# Q2/Q3: BOTH guest-booting scripts consume it, and both strip the defaults.
# -display none removes the display BACKEND; the stdvga DEVICE stays on the bus
# without -nodefaults -vga none. That device is the one his fourth QEMU bug was
# in, and it was present in every session this project had ever run.
for f in vm.sh build-base.sh; do
  src="$(cat "${ROOT}/scripts/${f}")"
  for needle in '-nodefaults' '-vga none' 'QEMU_MACHINE_OPTS'; do
    case "$src" in
    *"$needle"*) _pass Q2 "scripts/${f} passes ${needle}" ;;
    *) _fail Q2 "scripts/${f} passes ${needle}" "not found in scripts/${f}" ;;
    esac
  done
done

# Q4: the escape we do not have (threat: no-slirp). -netdev user needs no bridge,
# no root and no qemu-bridge-helper, so it is the tempting fix for any networking
# problem -- and it links libslirp, which is a published escape chain. Scoped to
# the SESSION path: build-base.sh does use SLIRP, unprivileged and by necessity,
# which is stated in threat-model.md rather than hidden behind a passing test.
case "$(cat "${ROOT}/scripts/vm.sh")" in
*"-netdev user"* | *"netdev=user"*) _fail Q4 "no SLIRP in the session path" "vm.sh mentions -netdev user; see threat: no-slirp" ;;
*) _pass Q4 "no SLIRP in the session path (the guest is on a tap)" ;;
esac

report
