#!/usr/bin/env bash
# home.sh — the agent home ($MOUNT_HOME), whatever medium it lives on.
#
#   init          create the storage tree with its ownership classes, then seed
#   seed [--force]  copy guest/configs dotfiles into the home (copy-if-missing;
#                 --force re-pushes the repo's version over in-guest edits)
#
# The guest mounts $MOUNT_HOME AS /home/agent, so dotfiles cannot come from the
# image (the mount would shadow them). guest/configs/ is the source of truth.
# An encrypted key is optional and handled by utils/disk.sh; point MOUNT_HOME at
# its mountpoint in config.local.sh, then `kata home seed`.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

die() {
  echo "home: $*" >&2
  exit 1
}

preflight() {
  [[ $EUID -eq 0 ]] || die "run as root (kata home wraps this in sudo)"
  [[ -n "$HOST_USER" ]] || die "HOST_USER unset — run via sudo so SUDO_USER is set"
  id -u "$AGENT_USER" >/dev/null 2>&1 || die "agent user '$AGENT_USER' does not exist"
}

# repo-relative source | path under the home | mode
seed_rows() {
  cat <<EOF
configs/zsh/zshrc|.zshrc|644
configs/npm/npmrc|.npmrc|644
configs/fastfetch/config.jsonc|.config/fastfetch/config.jsonc|644
configs/fastfetch/logo.ans|.config/fastfetch/logo.ans|644
configs/fastfetch/word.txt|.config/fastfetch/word.txt|644
configs/agents/AGENTS.md|.agents/AGENTS.md|644
EOF
}

# Every agent CLI reads its instructions under a different name; all point at
# the one ~/.agents/AGENTS.md.   link path | target (relative to the home)
seed_link_rows() {
  cat <<EOF
.claude/CLAUDE.md|.agents/AGENTS.md
.codex/AGENTS.md|.agents/AGENTS.md
EOF
}

# `install -D` creates missing parents as root; give the agent the whole chain,
# or e.g. ~/.config stays root-owned and the agent gets EACCES in its own home.
chown_chain() {
  local home="$1" dir="$2"
  while [[ "$dir" == "$home"/* ]]; do
    chown "${AGENT_USER}:${AGENT_USER}" "$dir"
    dir="$(dirname "$dir")"
  done
  return 0
}

# Links must be RELATIVE: created here as $MOUNT_HOME/…, resolved in the guest
# as /home/agent/…. An absolute target dangles in one of the two.
seed_links() {
  local home="$1" force="$2" link target from dir up rel c
  while IFS='|' read -r link target; do
    from="${home}/${link}"
    dir="$(dirname "$link")"
    up=""
    if [[ "$dir" != "." ]]; then
      for c in ${dir//\// }; do up+="../"; done
    fi
    rel="${up}${target}"
    # A stale symlink is ours to fix; a regular file there was put on purpose.
    if [[ -L "$from" && "$(readlink "$from")" != "$rel" ]]; then rm -f "$from"; fi
    if [[ -e "$from" || -L "$from" ]] && [[ "$force" != true ]]; then continue; fi
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$(dirname "$from")"
    chown_chain "$home" "$(dirname "$from")"
    ln -sfn "$rel" "$from"
    chown -h "${AGENT_USER}:${AGENT_USER}" "$from"
    echo "[seed] ${link} -> ${rel}"
  done < <(seed_link_rows)
  return 0
}

# Your PUBLIC key, so `kata ssh` skips the guest password. It grants login into
# the sandbox, never anything out of it. Never forward an agent socket (`ssh -A`).
seed_ssh_key() {
  local home="$1" force="$2" pub="" c hhome auth
  hhome="$(getent passwd "${HOST_USER}" | cut -d: -f6)"
  [[ -n "$hhome" ]] || return 0
  for c in "${KATA_SSH_KEY_NAME}.pub" id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
    if [[ -r "${hhome}/.ssh/${c}" ]]; then
      pub="${hhome}/.ssh/${c}"
      break
    fi
  done
  if [[ -z "$pub" ]]; then
    echo "[seed] no ssh public key for ${HOST_USER} — 'kata ssh' will ask for the guest password"
    return 0
  fi
  auth="${home}/.ssh/authorized_keys"
  if [[ -e "$auth" && "$force" != true ]]; then
    # Targeted fix, not `seed --force`, which would also overwrite dotfiles.
    if ! cmp -s "$pub" "$auth"; then
      echo "[seed] .ssh/authorized_keys differs from ${pub##*/}, left alone — fix: sudo install -o ${AGENT_USER} -g ${AGENT_USER} -m 600 ${pub} ${auth}"
    fi
    return 0
  fi
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 700 "${home}/.ssh"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 600 "$pub" "$auth"
  echo "[seed] .ssh/authorized_keys  (from ${pub})"
  return 0
}

seed_home() {
  local force="$1" home="$MOUNT_HOME" src dst mode from to n=0 skipped=0
  while IFS='|' read -r src dst mode; do
    from="${REPO_ROOT}/guest/${src}"
    to="${home}/${dst}"
    [[ -f "$from" ]] || die "missing source config: $from"
    if [[ -e "$to" && "$force" != true ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    install -D -o "$AGENT_USER" -g "$AGENT_USER" -m "$mode" "$from" "$to"
    chown_chain "$home" "$(dirname "$to")"
    echo "[seed] ${dst}"
    n=$((n + 1))
  done < <(seed_rows)
  seed_links "$home" "$force"
  seed_ssh_key "$home" "$force"
  if [[ $skipped -gt 0 ]]; then
    echo "[seed] ${n} written, ${skipped} already present (--force to overwrite)"
  fi
}

cmd_seed() {
  preflight
  local force=false
  if [[ "${1:-}" == "--force" ]]; then force=true; fi
  echo "[*] seeding ${MOUNT_HOME}"
  require_storage "$MOUNT_HOME"
  seed_home "$force"
}

# Plain directories with the ownership classes the security model depends on:
#   $MOUNT_HOME          agent:agent 755  755 so you can `git fetch` from it
#   $VM_BASES_DIR        you:you     700  parsed as root by vm.sh: never
#                                         agent-writable (threat: base-poisoning)
#   $SHARED_STORAGE_DIR  you:you     755  agent ro
# Refuses a mountpoint: that is a mounted volume, not a tree to create.
cmd_init() {
  preflight
  local rows=(
    "${MOUNT_HOME}|${AGENT_USER}:${AGENT_USER}|755"
    "${SHARED_STORAGE_DIR}|${HOST_USER}:${HOST_USER}|755"
    "${SHARED_SRC_DIR}|${HOST_USER}:${HOST_USER}|755"
    "${VM_BASES_DIR}|${HOST_USER}:${HOST_USER}|700"
  )
  local row d owner mode
  for row in "${rows[@]}"; do
    IFS='|' read -r d owner mode <<<"$row"
    if mountpoint -q "$d"; then die "$d is a mountpoint — that is a mounted volume, not a plain tree"; fi
    install -d -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$d"
    printf '  %-28s %-16s %s\n' "$d" "$owner" "$mode"
  done
  seed_home false
  echo "[ok] storage ready — next: kata vm --ssh  (no snapshots on a plain tree: utils/disk.sh has them)"
}

sub="${1:-}"
shift || true
case "$sub" in
init) cmd_init ;;
seed) cmd_seed "$@" ;;
-h | --help | "")
  echo "usage: kata home {init | seed [--force]}"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
