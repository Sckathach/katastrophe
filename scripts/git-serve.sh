#!/usr/bin/env bash
# git-serve.sh — git daemon on the bridge: the project interchange hub.
#
# Serves the bare repos under $SHARED_SRC_DIR (created by project.sh) so the
# in-sandbox experience is plain `git pull` / `git push` instead of a
# cp/bundle/chown dance. Runs as YOU, not root: it binds an unprivileged port
# and must write repos you own — so a push from the sandbox lands as your uid
# through git's own receive-pack, never as filesystem write access.
#
# The read/write split is per-repo git config, checked by git itself:
#
#   <name>.git         export-ok, receivepack unset  → guest can FETCH only
#   <name>-agent.git   export-ok, daemon.receivepack → guest can fetch + PUSH
#
# `git daemon` disables receive-pack globally by default and allows per-repo
# override, which is exactly this shape. No hook is involved.
#
# No auth on git:// — the controls are: bound to $HOST_IP (bridge only, never
# 0.0.0.0), reachable only from $BRIDGE via the nft rules net-up.sh installs,
# per-repo export opt-in (NO --export-all), and receivepack on the egress repo
# only. The bridge's only peer is the sandbox, which is already the untrusted
# party in the threat model.
#
# Subcommands: up | down | status
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

die() {
  echo "git-serve: $*" >&2
  exit 1
}

# Pid of a *live* git daemon from the pidfile, or empty. Verifies the process is
# actually ours before anything kills it (pidfiles go stale, pids get reused).
daemon_pid() {
  local pid
  [[ -s "$GIT_DAEMON_PID" ]] || return 0
  pid="$(cat "$GIT_DAEMON_PID")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null | grep -q 'daemon' || return 0
  echo "$pid"
}

listening() { ss -lnt "sport = :${GIT_PORT}" 2>/dev/null | grep -q "${HOST_IP}:${GIT_PORT}"; }

cmd_up() {
  command -v git >/dev/null || die "install git"

  echo "[*] serving ${SHARED_SRC_DIR}"
  require_storage "$SHARED_SRC_DIR"
  [[ -d "$SHARED_SRC_DIR" ]] ||
    die "no $SHARED_SRC_DIR — run 'kata project add <repo>' first (it creates the bare repos)"
  [[ -O "$SHARED_SRC_DIR" ]] ||
    die "you must own $SHARED_SRC_DIR (the daemon writes pushed objects as you)"

  # git daemon cannot bind an address the host doesn't have. Without the bridge
  # it would exit with a bare "Cannot bind to ..." — say why instead.
  ip -o addr show to "${HOST_IP}/32" 2>/dev/null | grep -q . ||
    die "$HOST_IP is not on this host — bring the bridge up first: kata up"

  local pid
  pid="$(daemon_pid)"
  if [[ -n "$pid" ]]; then
    echo "[=] git daemon already running (pid $pid) on ${HOST_IP}:${GIT_PORT}"
    return 0
  fi
  # A stale pidfile from a crashed daemon: safe to drop, we just proved no live
  # daemon is behind it.
  rm -f "$GIT_DAEMON_PID"

  mkdir -p "$GIT_RUN_DIR"
  # --export-all is deliberately NOT passed: a repo is served only if it has a
  # git-daemon-export-ok file, so a stray checkout under $SHARED_SRC_DIR is
  # never exposed. --informative-errors tells the guest "repo not exported" /
  # "service not enabled" instead of a uniform "access denied" — the failure
  # mode we WANT the agent to be able to read, since these are not secrets.
  git daemon \
    --base-path="$SHARED_SRC_DIR" \
    --listen="$HOST_IP" \
    --port="$GIT_PORT" \
    --reuseaddr \
    --detach \
    --pid-file="$GIT_DAEMON_PID" \
    --informative-errors \
    --log-destination=syslog

  for _ in $(seq 1 30); do
    listening && break
    sleep 0.1
  done
  listening || die "git daemon did not bind ${HOST_IP}:${GIT_PORT} (journalctl -t git-daemon)"

  echo "[+] git daemon up: git://${HOST_IP}:${GIT_PORT}/ → ${SHARED_SRC_DIR} — in the sandbox: git clone git://${HOST_IP}:${GIT_PORT}/<name>.git"
}

cmd_down() {
  local pid
  pid="$(daemon_pid)"
  if [[ -z "$pid" ]]; then
    rm -f "$GIT_DAEMON_PID"
    echo "[=] git daemon not running"
    return 0
  fi
  kill "$pid"
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && die "git daemon (pid $pid) did not exit"
  rm -f "$GIT_DAEMON_PID"
  echo "[-] git daemon stopped"
}

cmd_status() {
  local pid
  # Which tree the repos come from is the storage mode, and the daemon serves
  # exactly one of them — a `kata git up` on the local tree next to a
  # `kata --usb project add` is two halves of a workflow that never meet.
  pid="$(daemon_pid)"
  if [[ -n "$pid" ]]; then
    echo "  pid       $pid ($GIT_DAEMON_PID)"
  else
    echo "  pid       not running"
  fi
  echo "  base-path $SHARED_SRC_DIR"
  echo "  listening $(ss -lnt "sport = :${GIT_PORT}" 2>/dev/null | awk 'NR>1 {print $4}' | paste -sd, - || true)"

  local repo name
  echo "  repos"
  for repo in "$SHARED_SRC_DIR"/*.git; do
    [[ -d "$repo" ]] || continue
    name="$(basename "$repo")"
    if [[ ! -e "${repo}/git-daemon-export-ok" ]]; then
      echo "    $name  NOT EXPORTED"
    elif [[ "$(git -C "$repo" config --bool daemon.receivepack 2>/dev/null)" == "true" ]]; then
      echo "    $name  fetch + push (egress)"
    else
      echo "    $name  fetch only (ingress)"
    fi
  done

  # Best effort: the daemon logs to the journal as user $UID, which you can read
  # for your own messages. Silent if the journal isn't readable here.
  echo "  recent log"
  journalctl -t git-daemon -n 5 --no-pager 2>/dev/null | sed 's/^/    /' || true
}

[[ $EUID -ne 0 ]] || die "run as yourself, not root (the daemon must own the repos it writes)"

sub="${1:-}"
shift || true
case "$sub" in
up) cmd_up "$@" ;;
down) cmd_down "$@" ;;
status) cmd_status "$@" ;;
-h | --help | "")
  echo "usage: git-serve {up|down|status}"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
