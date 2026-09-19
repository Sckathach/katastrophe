#!/usr/bin/env bash
# ssh.sh — open a shell in the running sandbox (`kata ssh`).
#
# The sandbox is a VM on a private bridge at a static address, so this is just
# `ssh agent@$VM_IP` with the right options — but there are three of them you
# have to get right every time, and a session you can only reach from the
# terminal that started it is not much of a session. Hence a command.
#
# Any number of these can be open at once, and closing one does nothing to the
# guest: `kata vm --ssh` detaches the VM (see vm-supervise.sh). To stop the
# guest, `poweroff` inside it or `kata vm --stop`.
#
#   kata ssh                 interactive shell
#   kata ssh nvidia-smi      run one command and exit (exit code is forwarded)
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

# Never ssh as root. vm.sh execs this at the end of a `--ssh` launch, where it
# is still root from the sudo that started the VM; without this the connection
# would carry root's environment and, more to the point, root's ~/.ssh — so key
# auth would silently fall back to the password prompt while a plain `kata ssh`
# used your key. Same session either way is the point.
# -H matters as much as -u: without it sudo keeps HOME=/root, so ssh would look
# for keys and config in root's home while a plain `kata ssh` used yours.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  exec sudo -H -u "$SUDO_USER" -- "$0" "$@"
fi

# Liveness goes through /proc (pid_alive), not `kill -0`: qemu runs as the
# agent uid, so kill(2) from your uid is EPERM and every running session looked
# dead from here while `kata vm` (root) saw it fine. See lib.sh.
if command -v jq >/dev/null && [[ -r "$VM_STATE_FILE" ]]; then
  pid="$(jq -r '.pid // empty' "$VM_STATE_FILE" 2>/dev/null || true)"
  if ! pid_alive "$pid"; then
    echo "no session running — start one with: kata vm --ssh" >&2
    exit 1
  fi
fi

# Throwaway guest: it gets a fresh host key every session (the root filesystem
# is a per-session overlay), so known_hosts would be a wall of warnings. The
# connection is to a private bridge that only this host can reach, and the
# thing on the other end is untrusted by construction — there is nothing for
# host-key checking to protect here.
#
# Password is `agent` (guest/cloud-init/user-data). If your public key was
# seeded into the agent home (`kata disk seed`), key auth is tried first and you
# are not asked for it.
SSH_OPTS=(
  -o UserKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
  -o LogLevel=ERROR
)

# ssh auto-discovers only the stock identity names (id_rsa/id_ecdsa/id_ed25519),
# so a purpose-named key like ~/.ssh/kata is silently ignored without -i — you
# just get a password prompt and no indication why. IdentitiesOnly stops ssh
# offering every other key in the agent first, which on a host with several
# matters: each rejected offer is an auth attempt, and sshd's MaxAuthTries can
# close the connection before it reaches the right one.
#
# This runs as $SUDO_USER with -H (see the re-exec above), so $HOME is YOUR home
# and not root's. That is why config.sh carries a basename rather than a path.
KATA_SSH_KEY="${HOME}/.ssh/${KATA_SSH_KEY_NAME}"
if [[ -r "$KATA_SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$KATA_SSH_KEY" -o IdentitiesOnly=yes)
fi

# KATA_SSH_DRYRUN prints the connection instead of making it. It exists for
# 11-test-detached-session.sh, which has to check that this script AGREES a
# session is running (the `kill -0` bug made it disagree with vm.sh) without
# hanging on the guest's password prompt in a non-interactive test.
if [[ -n "${KATA_SSH_DRYRUN:-}" ]]; then
  echo "would connect: ssh ${SSH_OPTS[*]} ${AGENT_USER}@${VM_IP} ${*:-}"
  exit 0
fi

if [[ $# -gt 0 ]]; then
  exec ssh "${SSH_OPTS[@]}" "${AGENT_USER}@${VM_IP}" -- "$@"
fi
exec ssh "${SSH_OPTS[@]}" "${AGENT_USER}@${VM_IP}"
