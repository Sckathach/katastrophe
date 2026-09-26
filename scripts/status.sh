#!/usr/bin/env bash
# status.sh — `kata status [--rules]`: is it working right now? Runs often, so
# fast and never prompts: what it cannot see without root is "unknown", not red.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

cmd_status() {
  local pad=9 rules=false
  [[ "${1:-}" == "--rules" ]] && rules=true

  printf "%-${pad}s %s\n" "home" "${MOUNT_HOME}"
  if [[ -d "$MOUNT_HOME" ]]; then
    printf "%-${pad}s %s\n" "" "$(df -h --output=avail "$MOUNT_HOME" 2>/dev/null | tail -1 | tr -d ' ') free, owner $(stat -c %U "$MOUNT_HOME" 2>/dev/null)"
  else
    warn "agent home missing: ${MOUNT_HOME}  (sudo utils/disk.sh mount, or kata home init)"
  fi

  if ip link show "$BRIDGE" &>/dev/null; then
    ok "bridge    ${BRIDGE} ${HOST_IP}/${PREFIX}"
  else
    err "bridge    ${BRIDGE} down — run: kata up"
  fi

  local pstate profile
  pstate="$(proxy_state)"
  case "$pstate" in
  ok)
    # From the gate's own 403: the only place a stale `kata up` shows. A
    # mismatch is reported, not judged (`--profile` is legitimate).
    profile="$(proxy_profile)"
    if [[ -n "$profile" && "$profile" != "$ALLOWLIST_PROFILE" ]]; then
      ok "egress    mitmproxy ${HOST_IP}:${PROXY_PORT} — gate live, profile=${profile} (config says ${ALLOWLIST_PROFILE})"
    else
      ok "egress    mitmproxy ${HOST_IP}:${PROXY_PORT} — denied a test host (gate live, profile=${profile:-?})"
    fi
    ;;
  wedged) err "egress    mitmproxy ${HOST_IP}:${PROXY_PORT} — socket accepts, no response. Wedged: kata down && kata up" ;;
  down) err "egress    mitmproxy ${HOST_IP}:${PROXY_PORT} — nothing listening. Run: kata up" ;;
  *) warn "egress    mitmproxy answered ${pstate}, expected 403 — is the addon loaded?" ;;
  esac

  # Optional services: absent is a normal state, not a failure.
  if listens "$HOST_IP" "$GIT_PORT"; then
    ok "git       daemon ${HOST_IP}:${GIT_PORT}"
  else
    warn "git       no daemon on ${HOST_IP}:${GIT_PORT} — kata git up"
  fi
  if listens "$HOST_IP" "$SEARXNG_PORT"; then
    ok "search    searxng ${HOST_IP}:${SEARXNG_PORT}"
  else
    warn "search    searxng not running — kata web up"
  fi

  # The one thing no unprivileged check can prove. If sudo declines without
  # prompting, it is unknown, not red.
  if sudo -n nft list table inet agent_isolate &>/dev/null; then
    ok "nft       agent_isolate loaded (persistent skuid drop)"
  elif sudo -n true &>/dev/null; then
    err "nft       agent_isolate NOT loaded — the persistent egress drop is missing"
  else
    printf "%-${pad}s %s\n" "nft" "agent_isolate unknown (needs sudo) — kata doctor"
  fi

  local pid
  if pid="$(session_pid)"; then
    local gpu to
    gpu="$(state_field gpu)" to="$(state_field to)"
    ok "vm        $(state_field session) — base=$(state_field base) gpu=${gpu} mem=$(state_field mem)${to:+ →bake ${to}}"
    printf "%-${pad}s %s\n" "" "qemu pid ${pid} · connect: kata ssh · stop: kata vm --stop"
  else
    printf "%-${pad}s %s\n" "vm" "no session running  (kata vm --ssh)"
  fi

  # What the kernel holds, not the .nft template: net-up.sh inserts the port
  # accepts at up time. Needs root, hence opt-in.
  if [[ "$rules" == true ]]; then
    echo
    echo "effective rules (ports: ${SANDBOX_HOST_PORTS}):"
    # The split target must not be the loop variable, or entries get dropped.
    local pair table chain
    for pair in "agent_vm input" "agent_vm forward" "agent_isolate output" "filter input"; do
      read -r table chain <<<"$pair"
      echo
      echo "--- inet ${table} ${chain} ---"
      sudo nft list chain inet "$table" "$chain" 2>/dev/null || warn "not loaded, or sudo declined"
    done
  fi
}

cmd_status "$@"
