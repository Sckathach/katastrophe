#!/usr/bin/env bash
# audit-egress.sh — run this INSIDE the sandbox (VM or GPU container) to verify
# the egress gate. It is NOT a host orchestrator like the other scripts here;
# copy it into the guest (or it's on the shared workspace) and run it there.
#
# It proves the §5c properties hold from the agent's vantage point:
#   T1  DNS to a public resolver is blocked   (no UDP/53 exfil channel)
#   T2  direct TCP to a public IP is blocked  (egress is proxy-only)
#   T3  raw / AF_PACKET sockets are unusable  (no L2/raw exfil below netfilter)
#   T4  the proxy IS reachable                (positive control — not "all dead")
#
# Exit 0 iff every test lands the expected way. Needs python3 + curl (both ship
# in the VM and the GPU container). The proxy IP/port + an allowlisted host can
# be overridden via env for non-default deployments.
set -u

PROXY_IP="${PROXY_IP:-10.201.0.1}"
PROXY_PORT="${PROXY_PORT:-8080}"
ALLOWED_URL="${ALLOWED_URL:-https://pypi.org/simple/}" # an allowlisted host
PUBLIC_DNS="${PUBLIC_DNS:-8.8.8.8}"
PUBLIC_IP="${PUBLIC_IP:-1.1.1.1}" # for the raw-TCP probe
TIMEOUT="${TIMEOUT:-4}"

pass=0
fail=0
ok() {
  printf '  \033[32m[PASS]\033[0m %s\n' "$1"
  pass=$((pass + 1))
}
bad() {
  printf '  \033[31m[FAIL]\033[0m %s\n' "$1"
  fail=$((fail + 1))
}
info() { printf '  \033[2m%s\033[0m\n' "$1"; }

echo "egress audit — proxy ${PROXY_IP}:${PROXY_PORT}, timeout ${TIMEOUT}s"

# T1 — DNS to a public resolver. Craft a minimal A query for example.com and
# send it over UDP/53. A reply means a working exfil channel (DNS tunnelling).
echo "T1  DNS to public resolver (${PUBLIC_DNS}:53) — expect BLOCKED"
if python3 - "$PUBLIC_DNS" "$TIMEOUT" <<'PY'; then
import socket, sys, struct
host, to = sys.argv[1], float(sys.argv[2])
# id=0x1234, RD=1, 1 question; QNAME=example.com, A/IN
q = struct.pack(">HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
for label in (b"example", b"com"):
    q += bytes([len(label)]) + label
q += b"\x00" + struct.pack(">HH", 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(to)
try:
    s.sendto(q, (host, 53)); s.recvfrom(512); sys.exit(0)   # got a reply → reachable
except OSError:
    sys.exit(1)                                             # timeout/refused → blocked
PY
  bad "DNS reply received — UDP/53 exfil channel is OPEN"
else ok "no DNS reply (blocked)"; fi

# T2 — direct TCP to a public IP, bypassing the proxy. Should never connect.
echo "T2  direct TCP ${PUBLIC_IP}:443 (no proxy) — expect BLOCKED"
if python3 - "$PUBLIC_IP" "$TIMEOUT" <<'PY'; then
import socket, sys
host, to = sys.argv[1], float(sys.argv[2])
s = socket.socket(); s.settimeout(to)
try: s.connect((host, 443)); sys.exit(0)   # connected → egress leaks
except OSError: sys.exit(1)                 # refused/timeout → blocked
PY
  bad "direct TCP connected — non-proxy egress is OPEN"
else ok "direct TCP refused/timed out (blocked)"; fi

# T3 — raw / AF_PACKET sockets. Even creating them should fail without
# CAP_NET_RAW; if they CAN be created, flag it (frames may bypass the OUTPUT
# hook — that's the case a seccomp profile would close).
echo "T3  raw/AF_PACKET socket creation — expect DENIED"
raw_out="$(
  python3 - <<'PY'
import socket
res = []
for fam, typ, name in (
    (socket.AF_PACKET, socket.SOCK_RAW, "AF_PACKET"),
    (socket.AF_INET, socket.SOCK_RAW, "AF_INET/SOCK_RAW"),
):
    try:
        socket.socket(fam, typ).close(); res.append(f"{name}:CREATED")
    except PermissionError: res.append(f"{name}:denied")
    except OSError as e:    res.append(f"{name}:err({e.errno})")
print(" ".join(res))
PY
)"
info "$raw_out"
if [[ "$raw_out" == *CREATED* ]]; then
  bad "a raw/AF_PACKET socket was created — frames still only reach the bridge, which is not L2-bridged to any wire, but verify"
else
  ok "raw/AF_PACKET denied"
fi

# T4 — positive control: the proxy must work, or the three PASSes above are
# just "the network is dead" rather than "the gate is doing its job".
echo "T4  proxy reachable (${ALLOWED_URL} via ${PROXY_IP}:${PROXY_PORT}) — expect OK"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$((TIMEOUT * 3))" \
  -x "http://${PROXY_IP}:${PROXY_PORT}" "$ALLOWED_URL" 2>/dev/null || true)"
if [[ "$code" =~ ^[23] ]]; then
  ok "proxy returned HTTP ${code}"
else bad "proxy returned '${code:-no-response}' — gate may be misconfigured (or host not on allowlist)"; fi

echo "----"
echo "result: ${pass} passed, ${fail} failed"
[[ $fail -eq 0 ]]
