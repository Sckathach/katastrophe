#!/usr/bin/env bash
# vm-supervise.sh — owns a DETACHED session (`kata vm --ssh`). vm.sh decides
# everything, then hands over under setsid via $RUN_DIR/session.env; from then
# on this process is qemu's parent and does the teardown. Not run by hand.
#
# The one rule: only a guest that powered off cleanly is baked. A killed guest
# has an unsynced filesystem, and baking it gives a base that boots into fsck.
set -euo pipefail

RUN_DIR="${1:?usage: vm-supervise.sh RUN_DIR}"
ENV_FILE="${RUN_DIR}/session.env"
[[ -r "$ENV_FILE" ]] || {
  echo "vm-supervise: no session.env in ${RUN_DIR}" >&2
  exit 1
}

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# session.env first, exported, so config.sh's `:-` defaults keep the session's
# values: an explicit --home, and HOST_USER (no SUDO_USER in a detached process;
# without it the bake stays root-owned).
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
  # Signal or error with qemu alive: stop it first. QEMU_CLEAN stays 0, so no bake.
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

# VFIO memlock (see vm.sh), set here because qemu inherits it from its parent.
if [[ "$GPU_MODE" == true ]]; then
  ulimit -l $(($(mem_kib "$MEM") + 1048576))
fi

log "launching qemu for session ${SESSION}"
"${QEMU_BASE[@]}" </dev/null &
QEMU_PID=$!

# Until the pid lands, the state file reads as a leftover.
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

# rc 0 is not enough: qemu exits 0 on SIGTERM too. `--stop --force` drops the
# no-bake marker first; it is the veto.
if [[ -e "${RUN_DIR}/no-bake" ]]; then
  log "forced stop (no-bake marker) — session not eligible for --to bake"
elif [[ $QEMU_RC -eq 0 ]]; then
  QEMU_CLEAN=1
  log "guest powered off cleanly"
else
  log "qemu exited ${QEMU_RC} — session not eligible for --to bake"
fi
