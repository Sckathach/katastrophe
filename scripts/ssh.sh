#!/usr/bin/env bash
# ssh.sh — a shell in the running sandbox (`kata ssh`). Any number at once;
# closing one does nothing to the guest.
#
#   kata ssh                 interactive shell
#   kata ssh nvidia-smi      run one command (exit code forwarded)
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

# vm.sh execs this while still root. Re-exec as you, with -H, or ssh would use
# root's ~/.ssh and fall back to the password.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  exec sudo -H -u "$SUDO_USER" -- "$0" "$@"
fi

if command -v jq >/dev/null && [[ -r "$VM_STATE_FILE" ]]; then
  pid="$(jq -r '.pid // empty' "$VM_STATE_FILE" 2>/dev/null || true)"
  if ! pid_alive "$pid"; then
    echo "no session running — start one with: kata vm --ssh" >&2
    exit 1
  fi
fi

# The guest gets a fresh host key every session (throwaway root), it sits on a
# private bridge only this host reaches, and it is untrusted by construction:
# host-key checking protects nothing here. Password is `agent`; a key seeded by
# `kata home seed` is tried first.
SSH_OPTS=(
  -o UserKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
)

# A named key is ignored without -i. IdentitiesOnly stops ssh offering every
# other key first and hitting MaxAuthTries. Never add -A.
KATA_SSH_KEY="${HOME}/.ssh/${KATA_SSH_KEY_NAME}"
if [[ -r "$KATA_SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$KATA_SSH_KEY" -o IdentitiesOnly=yes)
fi

# For 11-test-detached-session.sh: prove this script agrees a session is up
# without hanging on a password prompt.
if [[ -n "${KATA_SSH_DRYRUN:-}" ]]; then
  echo "would connect: ssh ${SSH_OPTS[*]} ${AGENT_USER}@${VM_IP} ${*:-}"
  exit 0
fi

if [[ $# -gt 0 ]]; then
  exec ssh "${SSH_OPTS[@]}" "${AGENT_USER}@${VM_IP}" -- "$@"
fi
exec ssh "${SSH_OPTS[@]}" "${AGENT_USER}@${VM_IP}"
