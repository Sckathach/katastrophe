#!/usr/bin/env bash
# net-up.sh — bridge, nft session gate, mitmproxy egress gate. Idempotent; once
# per boot (`kata up`).
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

[[ $EUID -eq 0 ]] || {
  echo "run as root (kata up)"
  exit 1
}

while (($#)); do
  case "$1" in
  --profile)
    ALLOWLIST_PROFILE="${2:?--profile needs a name (swe|research|local)}"
    shift 2
    ;;
  --profile=*)
    ALLOWLIST_PROFILE="${1#*=}"
    shift
    ;;
  -h | --help)
    echo "usage: kata up [--profile swe|research|local]"
    exit 0
    ;;
  *)
    echo "net-up.sh: unknown argument '$1'" >&2
    exit 1
    ;;
  esac
done

# Validate before any side effect, or a typo leaves the host half-up. The names
# live only in allowlist.py; a bash copy would eventually disagree.
if command -v python3 >/dev/null 2>&1; then
  KATA_ALLOWLIST_PROFILE="$ALLOWLIST_PROFILE" \
    python3 "${REPO_ROOT}/proxy/mitmproxy/allowlist.py" --check >/dev/null || exit 1
fi

# The persistent skuid drop is its own systemd unit, independent of this repo
# (nft/agent_isolate.nft explains why not nftables.service).
if ! nft list table inet agent_isolate &>/dev/null; then
  refuse "nft table 'agent_isolate' is not loaded" <<EOF
it is the persistent skuid=${AGENT_UID} → RFC1918/tailscale drop, and it is the
one rule that outlives this script. Review ${REPO_ROOT}/nft/agent_isolate.nft first.
If the unit is already installed then it FAILED: systemctl status agent-isolate
fix: sudo cp ${REPO_ROOT}/nft/agent_isolate.nft /etc/nftables.d/ && sudo cp ${REPO_ROOT}/nft/agent-isolate.service /etc/systemd/system/ && sudo systemctl enable --now agent-isolate.service
EOF
fi

# --- Bridge ---------------------------------------------------------------
if ! ip link show "$BRIDGE" &>/dev/null; then
  ip link add "$BRIDGE" type bridge
  ip addr add "${HOST_IP}/${PREFIX}" dev "$BRIDGE"
  ip link set "$BRIDGE" up
  echo "[+] bridge $BRIDGE up (${HOST_IP}/${PREFIX})"
else
  echo "[=] bridge $BRIDGE already present"
fi

# qemu-bridge-helper only attaches taps to bridges listed here.
mkdir -p /etc/qemu
if ! grep -qxF "allow ${BRIDGE}" /etc/qemu/bridge.conf 2>/dev/null; then
  echo "allow ${BRIDGE}" >>/etc/qemu/bridge.conf
  chmod 640 /etc/qemu/bridge.conf
  echo "[+] /etc/qemu/bridge.conf: allow ${BRIDGE}"
fi

# --- nftables -------------------------------------------------------------
# Delete-then-load: `nft -f` appends to existing chains. agent_isolate is never
# touched here.
nft delete table inet agent_vm 2>/dev/null || true
nft -f "${REPO_ROOT}/nft/agent_sandbox.nft"
echo "[+] nft table agent_vm loaded"

# --- Per-port accepts ($SANDBOX_HOST_PORTS) --------------------------------
# Drop is terminal across chains at one hook, so each port needs a hole in BOTH
# `inet filter input` (the host's) and `inet agent_vm input` (ours). The
# persistent one is comment-tagged so re-runs and net-down.sh remove exactly it.
#
# Nothing goes into agent_isolate: guest traffic arrives over the bridge with no
# skuid, and the only host process at the agent uid is qemu, which needs no TCP —
# so an escaped qemu cannot reach any host service.
purge_tagged() { # $1=table $2=chain $3=tag
  local h
  for h in $(nft --handle list chain inet "$1" "$2" 2>/dev/null |
    awk -v tag="$3" '$0 ~ tag {for(i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}'); do
    nft delete rule inet "$1" "$2" handle "$h" 2>/dev/null || true
  done
}
purge_tagged filter input alt-proxy-vm-ingress

# `inet filter` exists on stock nftables, not under ufw/firewalld; inserting into
# a missing table would abort the script. Without it, the host firewall owns the
# input hook, and we check it rather than assume.
HAVE_INET_FILTER=false
nft list table inet filter &>/dev/null && HAVE_INET_FILTER=true

for port in $SANDBOX_HOST_PORTS; do
  if [[ "$HAVE_INET_FILTER" == true ]]; then
    nft insert rule inet filter input \
      iifname "$BRIDGE" ip daddr "$HOST_IP" tcp dport "$port" accept \
      comment \"alt-proxy-vm-ingress\"
  fi
  nft insert rule inet agent_vm input \
    iifname "$BRIDGE" ip daddr "$HOST_IP" tcp dport "$port" accept
done
echo "[+] sandbox→host ports opened on ${HOST_IP}: ${SANDBOX_HOST_PORTS// /, }"

if [[ "$HAVE_INET_FILTER" == true ]]; then
  echo "[+] ingress punched through 'inet filter input'"
elif command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  # ufw prints an interface rule's action as a bare ALLOW, not "ALLOW IN".
  if ufw status 2>/dev/null | grep -qE "on ${BRIDGE}[[:space:]].*ALLOW"; then
    echo "[=] ufw: ALLOW on ${BRIDGE} — ok (agent_vm does the real filtering)"
  else
    # Safe: agent_vm input still drops everything else off the bridge.
    echo "[!] ufw has no ingress ALLOW for ${BRIDGE}, the sandbox cannot reach the proxy — fix: sudo ufw allow in on ${BRIDGE}"
  fi
else
  echo "[=] no 'inet filter' table — make sure your firewall accepts input on ${BRIDGE} for: ${SANDBOX_HOST_PORTS// /, }"
fi

# --- mitmproxy CA ---------------------------------------------------------
# Per-deployment, generated once; the private key never leaves the host.
# build-base.sh bakes the public cert into the guest.
install -d -m 0755 "$PROXY_CA_DIR"
if [[ ! -s "$PROXY_CA_PEM" ]]; then
  echo "[+] generating per-deployment mitmproxy CA at $PROXY_CA_DIR"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  openssl req -x509 -newkey rsa:4096 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 \
    -subj "/CN=katastrophe-mitm-ca/O=katastrophe" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign,digitalSignature" \
    >/dev/null 2>&1
  # mitmproxy wants key + cert concatenated.
  cat "$TMP/key.pem" "$TMP/cert.pem" >"$PROXY_CA_PEM"
  install -m 0644 "$TMP/cert.pem" "$PROXY_CA_CERT"
  rm -rf "$TMP"
  trap - EXIT
  echo "[!] new CA — run 'kata build-base' to refresh the VM trust store"
else
  echo "[=] mitmproxy CA already present at $PROXY_CA_PEM"
fi
install -d -m 0755 "$PROXY_ETC_DIR"
install -m 0644 "${REPO_ROOT}/proxy/mitmproxy/addon.py" "${PROXY_ETC_DIR}/addon.py"
install -m 0644 "${REPO_ROOT}/proxy/mitmproxy/allowlist.py" "${PROXY_ETC_DIR}/allowlist.py"
# IPv4-first resolution: mitmproxy has no Happy Eyeballs and hangs on hosts whose
# IPv6 is advertised but unroutable (see the file's header).
install -m 0644 "${REPO_ROOT}/proxy/mitmproxy/gai.conf" "${PROXY_ETC_DIR}/gai.conf"
install -m 0644 "$PROXY_CA_CERT" "$PROXY_CA_CERT_PUB"

# The container runs as 1000:1000 and must own the CA dir (reads the key, writes
# its leaf-cert cache).
chown -R 1000:1000 "$PROXY_CA_DIR"
chmod 0700 "$PROXY_CA_DIR"
chmod 0600 "$PROXY_CA_PEM"
chmod 0644 "$PROXY_CA_CERT"

# --- Upstream API keys ----------------------------------------------------
# From $UPSTREAM_KEYS_FILE (root, 0600), with the environment as a fallback for
# direct runs. Parsed, never sourced: it is data, and `source` would execute a
# fat-fingered edit as root. They reach only the container, never the guest.
declare -A _kata_keyvals=()
if [[ -f "$UPSTREAM_KEYS_FILE" ]]; then
  _envmode="$(stat -c '%a' "$UPSTREAM_KEYS_FILE")"
  _envowner="$(stat -c '%U' "$UPSTREAM_KEYS_FILE")"
  if [[ "$_envowner" != root || "$_envmode" != 600 ]]; then
    echo "[!] ${UPSTREAM_KEYS_FILE}: want root-owned mode 600, got ${_envowner} ${_envmode} — fix: sudo chown root:root ${UPSTREAM_KEYS_FILE} && sudo chmod 600 ${UPSTREAM_KEYS_FILE}" >&2
    exit 1
  fi
  while IFS= read -r _line || [[ -n "$_line" ]]; do
    if [[ "$_line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      _val="${BASH_REMATCH[3]}"
      _val="${_val%\"}" _val="${_val#\"}"
      _val="${_val%\'}" _val="${_val#\'}"
      _kata_keyvals["${BASH_REMATCH[2]}"]="$_val"
    fi
  done <"$UPSTREAM_KEYS_FILE"
  unset _line _val _envmode _envowner
fi

PROXY_KEY_ARGS=(
  -e "KATA_KEY_SENTINEL=${KEY_SENTINEL}"
  -e "KATA_ALLOWLIST_PROFILE=${ALLOWLIST_PROFILE}"
)
_kata_keys_found=()
for k in $UPSTREAM_API_KEYS; do
  v="${_kata_keyvals[$k]:-${!k:-}}"
  if [[ -n "$v" ]]; then
    PROXY_KEY_ARGS+=(-e "${k}=${v}")
    _kata_keys_found+=("$k")
  fi
done
unset v
# Names only, never values.
if ((${#_kata_keys_found[@]})); then
  echo "[*] upstream keys: ${_kata_keys_found[*]}"
else
  echo "[*] upstream keys: none, API-key providers will 502 — fix: KEY=value lines in ${UPSTREAM_KEYS_FILE} (root:root, 0600)"
fi

# --- mitmproxy (rootful podman, --network=host) ---------------------------
if podman container exists "$PROXY_NAME"; then
  podman rm -f "$PROXY_NAME" >/dev/null
fi

# Straight to mitmdump as 1000:1000: the image entrypoint su-execs, which needs
# CAP_SETUID and dies under --cap-drop=ALL. No --rm, so a crash keeps its logs.
podman run -d \
  --name "$PROXY_NAME" \
  --network=host \
  --user 1000:1000 \
  --entrypoint mitmdump \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  -v "${PROXY_CA_DIR}":/home/mitmproxy/.mitmproxy:Z \
  -v "${PROXY_ETC_DIR}/addon.py":/home/mitmproxy/addon.py:ro,Z \
  -v "${PROXY_ETC_DIR}/allowlist.py":/home/mitmproxy/allowlist.py:ro,Z \
  -v "${PROXY_ETC_DIR}/gai.conf":/etc/gai.conf:ro,Z \
  "${PROXY_KEY_ARGS[@]}" \
  "$PROXY_IMAGE" \
  --listen-host "$HOST_IP" \
  --listen-port "$PROXY_PORT" \
  --set confdir=/home/mitmproxy/.mitmproxy \
  --set stream_large_bodies=10m \
  --set block_global=false \
  -s /home/mitmproxy/addon.py >/dev/null

for _ in $(seq 1 40); do
  ss -lnt "sport = :${PROXY_PORT}" | grep -q "${HOST_IP}:${PROXY_PORT}" && break
  sleep 0.3
done
ss -lnt "sport = :${PROXY_PORT}" | grep -q "${HOST_IP}:${PROXY_PORT}" ||
  {
    echo "mitmproxy failed to bind ${HOST_IP}:${PROXY_PORT}"
    echo "--- podman logs ${PROXY_NAME} (last 60 lines) ---"
    podman logs --tail 60 "$PROXY_NAME" 2>&1 || true
    echo "--- container left running for inspection (podman rm -f ${PROXY_NAME}) ---"
    exit 1
  }

echo "[ok] net up — bridge=${BRIDGE} proxy=${HOST_IP}:${PROXY_PORT} (mitmproxy)"
echo "     allowlist profile: ${ALLOWLIST_PROFILE}  (kata up --profile NAME to change)"
