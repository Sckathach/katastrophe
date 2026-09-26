#!/usr/bin/env bash
# git-serve.sh — git daemon on the bridge (`kata git up|down|status`), serving
# the bare repos under $SHARED_SRC_DIR. Runs as you: a sandbox push lands as
# your uid through git's receive-pack, never as filesystem write access.
#
#   <name>.git         export-ok, receivepack unset  → guest can FETCH only
#   <name>-agent.git   export-ok, daemon.receivepack → guest can fetch + PUSH
#
# No auth on git://. The controls: bound to $HOST_IP only, reachable only from
# the bridge (nft), per-repo export opt-in, receive-pack on the egress repo only.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

die() {
  echo "git-serve: $*" >&2
  exit 1
}

# Pid of a live git daemon from the pidfile, or empty. Checks the cmdline too:
# pidfiles go stale and pids get reused.
daemon_pid() {
  local pid
  [[ -s "$GIT_DAEMON_PID" ]] || return 0
  pid="$(cat "$GIT_DAEMON_PID")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  pid_alive "$pid" || return 0
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

  # Otherwise git daemon dies with a bare "Cannot bind".
  ip -o addr show to "${HOST_IP}/32" 2>/dev/null | grep -q . ||
    die "$HOST_IP is not on this host — bring the bridge up first: kata up"

  local pid
  pid="$(daemon_pid)"
  if [[ -n "$pid" ]]; then
    echo "[=] git daemon already running (pid $pid) on ${HOST_IP}:${GIT_PORT}"
    return 0
  fi
  rm -f "$GIT_DAEMON_PID" # stale: no live daemon behind it

  # Rules are inserted at `kata up` time; a port added to config since then is
  # closed to the guest. Only checkable without a prompt if sudo is cached.
  if sudo -n nft list chain inet agent_vm input >/dev/null 2>&1 &&
    ! sudo -n nft list chain inet agent_vm input 2>/dev/null | grep -q "dport ${GIT_PORT}"; then
    echo "[!] no nft accept for ${GIT_PORT}, the sandbox will not reach the daemon — fix: kata up"
  fi

  mkdir -p "$GIT_RUN_DIR"
  # Never --export-all: only repos with git-daemon-export-ok are served.
  # --informative-errors: "not exported" / "service not enabled" are not secrets.
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
    pid_alive "$pid" || break
    sleep 0.1
  done
  if pid_alive "$pid"; then die "git daemon (pid $pid) did not exit"; fi
  rm -f "$GIT_DAEMON_PID"
  echo "[-] git daemon stopped"
}

cmd_status() {
  local pid
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

  # Best effort: silent if the journal is not readable here.
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
  echo "usage: kata git {up|down|status}"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
