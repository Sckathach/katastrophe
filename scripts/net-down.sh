#!/usr/bin/env bash
# net-down.sh — inverse of net-up.sh (`kata down`). Idempotent. agent_isolate is
# persistent and deliberately survives.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

[[ $EUID -eq 0 ]] || {
  echo "run as root (kata down)"
  exit 1
}

# searxng too: it binds $HOST_IP, which goes away with the bridge.
podman rm -f "$SEARXNG_NAME" 2>/dev/null >/dev/null || true
echo "[-] searxng stopped"
podman rm -f "$PROXY_NAME" 2>/dev/null >/dev/null || true
echo "[-] mitmproxy stopped"

# Our tagged accepts in the host's persistent input chain.
HANDLES=$(nft --handle list chain inet filter input 2>/dev/null |
  awk '/alt-proxy-vm-ingress/ {for(i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}')
for h in ${HANDLES}; do
  nft delete rule inet filter input handle "$h" 2>/dev/null || true
done
echo "[-] alt-proxy exceptions removed"

nft delete table inet agent_vm 2>/dev/null || true
echo "[-] nft table agent_vm removed"

if ip link show "$BRIDGE" &>/dev/null; then
  ip link del "$BRIDGE"
  echo "[-] bridge $BRIDGE removed"
fi

# The git daemon runs as you, so it is not ours to kill; without the bridge it
# is unreachable anyway. Checked by binding: its pidfile is under your
# XDG_RUNTIME_DIR, which sudo does not hand us.
if ss -lnt "sport = :${GIT_PORT}" 2>/dev/null | grep -q "${HOST_IP}:${GIT_PORT}"; then
  echo "[=] git daemon still running (now unreachable) — 'kata git down' to stop it"
fi

echo "[ok] net down"
