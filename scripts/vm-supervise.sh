#!/usr/bin/env bash
# vm-supervise.sh — owns a DETACHED sandbox session (`kata vm --ssh`).
#
# vm.sh does all the deciding (arg parsing, guards, virtiofsd, the qemu argv)
# and then hands the session to this script under `setsid`, so the guest stops
# depending on the terminal that started it. From that moment this process is
# the session: it is qemu's parent, it waits for it, and it does the teardown
# vm.sh's cleanup() would otherwise have done —
#
#   * bake --to into a versioned warm base, but ONLY on a clean guest poweroff
#   * kill the virtiofsds vm.sh started
#   * remove the overlay, the run dir and the state file
#
# Everything it needs arrives in $RUN_DIR/session.env (written by vm.sh, root
# owned, under /run), including the exact qemu argv via `declare -p`. It is not
# meant to be run by hand.
#
# Nothing here parses user input. The one rule to keep: a session that ended for
# ANY reason other than qemu exiting 0 must not be baked — a killed or crashed
# guest has an unsynced filesystem, and freezing that into a base is how you get
# a warm base that boots into fsck.
set -euo pipefail

RUN_DIR="${1:?usage: vm-supervise.sh RUN_DIR}"
ENV_FILE="${RUN_DIR}/session.env"
[[ -r "$ENV_FILE" ]] || {
  echo "vm-supervise: no session.env in ${RUN_DIR}" >&2
  exit 1
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# session.env FIRST, then config.sh, and the three exports are what makes that
# order work: every declaration in config.sh is `${VAR:-default}`, so an exported
# value from the session survives it. That matters because the session's home may
# have come from an explicit `--home`, and because HOST_USER comes from $SUDO_USER,
# which does not exist in a detached process — without it the baked base would stay
# root-owned in a you-owned directory.
# shellcheck disable=SC1090
source "$ENV_FILE"
export HOST_USER VM_BASES_DIR MOUNT_HOME
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

QEMU_PID=""
QEMU_CLEAN=0

finish() {
  set +e
  # A signal (or an error) while qemu is alive: take it down first so the
  # overlay is flushed before anything reads it. QEMU_CLEAN stays 0 on that
  # path, so this can never turn into a bake.
  if [[ -n "$QEMU_PID" ]] && pid_alive "$QEMU_PID"; then
    log "terminating qemu (pid ${QEMU_PID})"
    kill "$QEMU_PID" 2>/dev/null
    wait "$QEMU_PID" 2>/dev/null
  fi
  if [[ -n "$TO_NAME" && $QEMU_CLEAN -eq 1 ]]; then
    save_base "$OVERLAY" "$TO_NAME" "$FROM_NAME" "$GPU_MODE"
  fi
  for p in "${VFS_PIDS[@]}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -f "$VM_STATE_FILE"
  rm -f "$OVERLAY"
  rm -rf "$RUN_DIR"
  log "session ${SESSION} cleaned up"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# RLIMIT_MEMLOCK for VFIO — see the long explanation in vm.sh. It has to be set
# HERE, not there: the limit is inherited from qemu's parent, and in a detached
# session that parent is this process.
if [[ "$GPU_MODE" == true ]]; then
  ulimit -l $(($(mem_kib "$MEM") + 1048576))
fi

log "launching qemu for session ${SESSION}"
"${QEMU_BASE[@]}" </dev/null &
QEMU_PID=$!

# Publish the pid: `kata vm --status`, `kata ssh` and the one-session-at-a-time
# check all key off it, and until it lands the state file looks like a leftover.
if command -v jq >/dev/null && [[ -r "$VM_STATE_FILE" ]]; then
  tmp="${VM_STATE_FILE}.tmp"
  if jq --argjson pid "$QEMU_PID" '.pid = $pid' "$VM_STATE_FILE" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$VM_STATE_FILE"
    chmod 0644 "$VM_STATE_FILE" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
fi

QEMU_RC=0
wait "$QEMU_PID" || QEMU_RC=$?
QEMU_PID="" # reaped — don't let finish() signal a stale pid

# Exit status alone is NOT enough to mean "the guest powered off cleanly":
# qemu handles SIGTERM as a shutdown request and exits 0, so `kata vm --stop
# --force` — which promises no bake — would look identical to a real poweroff
# and flatten a half-provisioned session over the warm base it was replacing.
# cmd_stop drops $RUN_DIR/no-bake before signalling; that file is the veto.
if [[ -e "${RUN_DIR}/no-bake" ]]; then
  log "forced stop (no-bake marker) — session not eligible for --to bake"
elif [[ $QEMU_RC -eq 0 ]]; then
  QEMU_CLEAN=1
  log "guest powered off cleanly"
else
  log "qemu exited ${QEMU_RC} — session not eligible for --to bake"
fi
