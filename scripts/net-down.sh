#!/usr/bin/env bash
# net-down.sh — inverse of net-up.sh. Idempotent.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

[[ $EUID -eq 0 ]] || {
  echo "run as root (sudo $0)"
  exit 1
}

# Containers. searxng is brought up separately (`kata web up`) but torn down
# here regardless: it binds $HOST_IP, which disappears with the bridge below.
podman rm -f "$SEARXNG_NAME" 2>/dev/null >/dev/null || true
echo "[-] searxng stopped"
# Literal name, not a config var: litellm was deleted 2026-09-11 and the var
# went with it, but a container from an older checkout can still be running.
podman rm -f agent-litellm 2>/dev/null >/dev/null || true
podman rm -f "$PROXY_NAME" 2>/dev/null >/dev/null || true
echo "[-] mitmproxy stopped"

# Scoped exception rules inserted into the two PERSISTENT chains. `filter input`
# is the live one. `agent_isolate output` no longer receives any (the GPU
# container path that needed them is gone — see net-up.sh), but keep purging it
# so tearing down after an older net-up.sh still leaves the table clean.
for spec in "agent_isolate output alt-proxy-exception" \
  "filter input alt-proxy-vm-ingress"; do
  # shellcheck disable=SC2086
  set -- $spec
  HANDLES=$(nft --handle list chain inet "$1" "$2" 2>/dev/null |
    awk -v tag="$3" '$0 ~ tag {for(i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}')
  for h in ${HANDLES}; do
    nft delete rule inet "$1" "$2" handle "$h" 2>/dev/null || true
  done
done
echo "[-] alt-proxy exceptions removed"

# Session table. agent_isolate is persistent and deliberately survives.
nft delete table inet agent_vm 2>/dev/null || true
# Left over from a pre-2026-08 net-up.sh (GPU container path); harmless if absent.
nft delete table inet agent_uid_egress 2>/dev/null || true
echo "[-] nft table agent_vm removed"

# Bridge
if ip link show "$BRIDGE" &>/dev/null; then
  ip link del "$BRIDGE"
  echo "[-] bridge $BRIDGE removed"
fi

# The git daemon runs as YOU, not root, so it isn't ours to kill — and with the
# bridge and the port accepts gone it is unreachable from any sandbox. Stop it
# explicitly with `kata git down` if you want the process gone too.
# (We check the binding, not GIT_DAEMON_PID: the pidfile lives under the
# invoking user's XDG_RUNTIME_DIR, which sudo does not hand us.)
if ss -lnt "sport = :${GIT_PORT}" 2>/dev/null | grep -q "${HOST_IP}:${GIT_PORT}"; then
  echo "[=] git daemon still running (now unreachable) — 'kata git down' to stop it"
fi

echo "[ok] net down"
