#!/usr/bin/env bash
# net-up.sh — bring up bridge virbr-agent, nft tables, and the mitmproxy
# egress gate. Idempotent. Run once per boot (or after net-down.sh).
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

[[ $EUID -eq 0 ]] || {
  echo "run as root (sudo $0)"
  exit 1
}

# --- args -----------------------------------------------------------------
# Only one, and it is a policy selector rather than a secret, so it rides on the
# command line and needs none of the $UPSTREAM_KEYS_FILE machinery below. Note
# `kata up` passes its args straight through, so `kata up --profile research`
# lands here directly — no sudo env threading, nothing for env_reset to eat.
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
    echo "usage: net-up.sh [--profile swe|research|local]"
    exit 0
    ;;
  *)
    echo "net-up.sh: unknown argument '$1'" >&2
    exit 1
    ;;
  esac
done

# Validate the profile HERE — before the bridge, the nft tables, the CA, the
# container, anything. allowlist.py refuses to import with a bad name, so the
# proxy could never come up wrong; but that refusal happens at the END of this
# script, which left the host half-up: bridge and gate tables loaded, no proxy.
# Fail-closed (the guest reaches nothing) and `kata vm` refuses to launch, so it
# was never dangerous — it was a typo costing a teardown. Argument validation
# belongs before side effects.
#
# allowlist.py is the only thing that knows the profile names, and it stays that
# way: a copy of the list in bash is the copy that eventually disagrees.
if command -v python3 >/dev/null 2>&1; then
  KATA_ALLOWLIST_PROFILE="$ALLOWLIST_PROFILE" \
    python3 "${REPO_ROOT}/proxy/mitmproxy/allowlist.py" --check >/dev/null || exit 1
fi

# --- Preflight: persistent agent_isolate ----------------------------------
# Load-bearing rule. Installed as its own systemd unit so it survives reboots
# independently of both this repo and whatever else filters on the host
# (see the header of nft/agent_isolate.nft for why not nftables.service).
if ! nft list table inet agent_isolate &>/dev/null; then
  refuse "nft table 'agent_isolate' is not loaded" <<EOF
it is the persistent skuid=${AGENT_UID} → RFC1918/tailscale drop, and it is the
one rule that outlives this script. Review ${REPO_ROOT}/nft/agent_isolate.nft first.
If the unit is already installed then it FAILED: systemctl status agent-isolate
fix: sudo cp ${REPO_ROOT}/nft/agent_isolate.nft /etc/nftables.d/ && sudo cp ${REPO_ROOT}/nft/agent-isolate.service /etc/systemd/system/ && sudo systemctl enable --now agent-isolate.service
EOF
fi

# --- Migration: strip stale agent ACLs off the GPU devices ----------------
# disk.sh used to `setfacl -m u:agent:rw /dev/nvidia*` on every mount so the
# rootless GPU container could reach the driver. That container is gone, and
# the process running as uid $AGENT_UID now is *qemu* — so those ACLs would
# hand an escaped qemu direct ioctl access to the NVIDIA driver, the exact
# ring-0 surface VFIO exists to take away. The grant is deleted, but ACLs set
# by an older checkout survive until the device nodes are recreated (i.e. a
# reboot), so clear them here: this runs as root, once per boot, before
# anything can use them. Only the agent's entry is removed — your own access
# and the base mode bits are untouched.
strip_agent_dev_acls() {
  command -v setfacl >/dev/null 2>&1 || return 0
  local dev stripped=0
  shopt -s nullglob
  for dev in /dev/nvidia* /dev/dri/card* /dev/dri/render*; do
    [[ -e "$dev" ]] || continue
    if getfacl -p -- "$dev" 2>/dev/null | grep -q "^user:${AGENT_USER}:"; then
      setfacl -x "u:${AGENT_USER}" -- "$dev" 2>/dev/null && stripped=$((stripped + 1))
    fi
  done
  shopt -u nullglob
  if ((stripped > 0)); then
    echo "[+] stripped ${stripped} stale ${AGENT_USER} ACL(s) from the GPU devices"
  fi
  return 0
}
strip_agent_dev_acls

# --- Bridge ---------------------------------------------------------------
if ! ip link show "$BRIDGE" &>/dev/null; then
  ip link add "$BRIDGE" type bridge
  ip addr add "${HOST_IP}/${PREFIX}" dev "$BRIDGE"
  ip link set "$BRIDGE" up
  echo "[+] bridge $BRIDGE up (${HOST_IP}/${PREFIX})"
else
  echo "[=] bridge $BRIDGE already present"
fi

# --- qemu bridge helper ACL -----------------------------------------------
# qemu-bridge-helper refuses to attach a tap to a bridge that isn't listed.
mkdir -p /etc/qemu
if ! grep -qxF "allow ${BRIDGE}" /etc/qemu/bridge.conf 2>/dev/null; then
  echo "allow ${BRIDGE}" >>/etc/qemu/bridge.conf
  chmod 640 /etc/qemu/bridge.conf
  echo "[+] /etc/qemu/bridge.conf: allow ${BRIDGE}"
fi

# --- nftables -------------------------------------------------------------
# Delete-then-load so a re-run replaces the rules instead of appending a second
# copy of every one (the file declares chains, and `nft -f` appends to an
# existing chain). agent_isolate — the load-bearing persistent drop — is never
# touched here; only this session table is recreated.
nft delete table inet agent_vm 2>/dev/null || true
nft -f "${REPO_ROOT}/nft/agent_sandbox.nft"
echo "[+] nft table agent_vm loaded"

# --- per-port accepts (single source: $SANDBOX_HOST_PORTS) -----------------
# Every host service the sandbox may reach needs a hole punched in TWO places,
# because `drop`/`reject` is terminal across chains at the same hook:
#
#   inet filter input     the host's own main input chain
#   inet agent_vm input   this session's gate
#
# The insert into the PERSISTENT chain (filter input) carries a comment tag so
# this script and net-down.sh can find and remove exactly their own rules; the
# session table needs none (it's recreated wholesale above). Insert prepends, so
# accepts land ahead of the terminal drop.
#
# NOTE — nothing is punched into `agent_isolate` any more, and that is a
# tightening we get for free from deleting the GPU container path. That table
# drops skuid=AGENT_UID → RFC1918, and 10.201.0.1 is in 10/8, so the container
# (whose host sockets carried skuid 1001) needed exceptions to reach the proxy
# at all. The VM does not: its traffic arrives over the bridge and carries no
# skuid. The only thing still running as uid 1001 on the host is qemu itself,
# after `-run-with user=` — and qemu needs no TCP of its own. So an escaped
# qemu now cannot reach mitmproxy, the git daemon or searxng, where
# before it could. If you ever add a host-side helper that runs as the agent
# uid and must reach a host port, this is the comment that explains why it
# fails, and `purge_tagged agent_isolate output alt-proxy-exception` (removed
# here) is the shape of the fix.
purge_tagged() { # $1=table $2=chain $3=tag
  local h
  for h in $(nft --handle list chain inet "$1" "$2" 2>/dev/null |
    awk -v tag="$3" '$0 ~ tag {for(i=1;i<=NF;i++) if ($i=="handle") print $(i+1)}'); do
    nft delete rule inet "$1" "$2" handle "$h" 2>/dev/null || true
  done
}

# Clear any exceptions left in agent_isolate by a pre-2026-08 net-up.sh, so an
# upgrade actually tightens instead of leaving stale holes behind.
purge_tagged agent_isolate output alt-proxy-exception
purge_tagged filter input alt-proxy-vm-ingress

# `inet filter` is the Arch/stock-nftables main input chain. It is NOT
# universal: a host running ufw or firewalld filters in the `ip`/`ip6` families
# and has no `inet filter` table at all. Inserting into a table that doesn't
# exist is a hard error, which under `set -e` aborted this whole script — found
# the hard way, `kata up` died right here on a ufw host, leaving agent_vm with
# no port accepts and both proxies unstarted.
#
# So punch through it only when it exists. When it doesn't, the host's own
# firewall owns the input hook, and we CHECK that rather than assume it.
# Note a broad upstream "allow anything on the bridge" widens nothing:
# `agent_vm input` still ends in a terminal drop, and drop wins across chains
# at the same hook.
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
else
  echo "[=] no 'inet filter' table — your host firewall owns the input hook"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    # Match the interface and the verb separately. `ufw status` renders an
    # interface rule as "Anywhere on virbr-agent    ALLOW    Anywhere" — the
    # action column is a bare ALLOW, NOT "ALLOW IN" (ufw only appends a
    # direction for non-default ones like ALLOW OUT / ALLOW FWD). Grepping for
    # "ALLOW IN" therefore reported a correctly-configured host as unconfigured,
    # twice, and sent me chasing a firewall that was never the problem.
    if ufw status 2>/dev/null | grep -qE "on ${BRIDGE}[[:space:]].*ALLOW"; then
      echo "    ufw: ALLOW on ${BRIDGE} — ok (agent_vm does the real filtering)"
    else
      echo "[!] ufw is active but has no ingress ALLOW rule for ${BRIDGE}."
      echo "    The sandbox will not reach the proxies. Fix with:"
      echo "        sudo ufw allow in on ${BRIDGE}"
      echo "    Safe: agent_vm input drops everything off the bridge except"
      echo "    ${SANDBOX_HOST_PORTS// /, } + icmp, and drop is terminal across chains."
    fi
  else
    echo "    Ensure it accepts input on ${BRIDGE} for: ${SANDBOX_HOST_PORTS// /, }"
  fi
fi

# --- mitmproxy CA bootstrap ----------------------------------------------
# Per-deployment CA. Generated once via openssl; private key never leaves the
# host. The public cert is later picked up by build-base.sh and baked into the
# guest's trust store via cloud-init's `ca_certs` module.
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
  # mitmproxy expects key + cert concatenated in mitmproxy-ca.pem.
  cat "$TMP/key.pem" "$TMP/cert.pem" >"$PROXY_CA_PEM"
  install -m 0644 "$TMP/cert.pem" "$PROXY_CA_CERT"
  rm -rf "$TMP"
  trap - EXIT
  echo "[!] new CA — run 'kata build-base' to refresh the VM trust store"
else
  echo "[=] mitmproxy CA already present at $PROXY_CA_PEM"
fi
install -d -m 0755 "$PROXY_ETC_DIR"
# addon.py imports allowlist.py (the host list) from its own dir, so ship both
# and bind-mount both into the container (see podman run below).
install -m 0644 "${REPO_ROOT}/proxy/mitmproxy/addon.py" "${PROXY_ETC_DIR}/addon.py"
install -m 0644 "${REPO_ROOT}/proxy/mitmproxy/allowlist.py" "${PROXY_ETC_DIR}/allowlist.py"
# Makes the container resolve IPv4-first. Load-bearing on any host whose IPv6
# is advertised but unroutable — mitmproxy has no Happy Eyeballs, so it hangs
# on every AAAA-bearing host instead of falling back. See the file's header.
install -m 0644 "${REPO_ROOT}/proxy/mitmproxy/gai.conf" "${PROXY_ETC_DIR}/gai.conf"
# Public CA cert, copied out of the 0700 CA dir into this 0755 dir. The guest
# gets the CA baked into its trust store at build time (build-base.sh reads
# $PROXY_CA_CERT); this world-readable copy is what anything else on the host
# can point at without needing to traverse the key directory. Public cert only
# — the private key never leaves PROXY_CA_DIR.
install -m 0644 "$PROXY_CA_CERT" "$PROXY_CA_CERT_PUB"

# Chown the host CA dir to 1000:1000 so the container's mitmproxy user
# (uid 1000) owns it: reads the CA key and writes the per-host leaf-cert
# cache it generates at runtime. uid 1000 is the typical first human user
# (who owns this repo checkout) — no new privilege exposure beyond host DAC.
#
# We run the container as --user 1000:1000 (see podman run below) so the
# image entrypoint's root branch is skipped entirely. That branch stats
# this dir as root and usermods to match; under --cap-drop=ALL the root
# entrypoint has no CAP_DAC_READ_SEARCH and can't traverse a 0700 dir it
# doesn't own, so the stat fails (EACCES) and usermod aborts with
# "invalid user ID '-g'". Starting as uid 1000 avoids the whole dance.
chown -R 1000:1000 "$PROXY_CA_DIR"
chmod 0700 "$PROXY_CA_DIR"
chmod 0600 "$PROXY_CA_PEM"
chmod 0644 "$PROXY_CA_CERT"

# --- upstream API keys ----------------------------------------------------
# Real provider credentials, handed to the proxy container so the addon can swap
# them in for the sentinel the guest sends (see proxy/mitmproxy/addon.py). They
# reach the container as environment variables, readable only by whoever can
# already run rootful podman — i.e. root. They never touch the guest.
#
# WHERE THEY COME FROM, and why it isn't your shell: `kata up` invokes this
# script as plain `sudo net-up.sh` (no -E), and sudo's env_reset drops
# *_API_KEY before we ever run. Exporting a key in your shell therefore does
# NOTHING here — it looks like it should work and silently doesn't. So the
# canonical source is $UPSTREAM_KEYS_FILE, a root-owned 0600 file of KEY=value
# lines. The process environment stays a fallback, for running this script
# directly or under `sudo -E`.
#
# This block is the one piece of litellm worth keeping; it long outlived the
# container it was written for.
if [[ ! -f "$UPSTREAM_KEYS_FILE" && -f /etc/agent-litellm/env ]]; then
  # Migration from the litellm era (deleted 2026-09-11). Same format, same
  # permissions, new home next to the proxy that now consumes it.
  echo "[!] found the old litellm secrets file. Move it:" >&2
  echo "      sudo mv /etc/agent-litellm/env ${UPSTREAM_KEYS_FILE}" >&2
  echo "      sudo rmdir /etc/agent-litellm" >&2
fi

declare -A _kata_keyvals=()
if [[ -f "$UPSTREAM_KEYS_FILE" ]]; then
  # A secrets file that the agent uid (or anyone else) can read defeats the
  # point of keeping the keys off the guest. Refuse rather than warn.
  _envmode="$(stat -c '%a' "$UPSTREAM_KEYS_FILE")"
  _envowner="$(stat -c '%U' "$UPSTREAM_KEYS_FILE")"
  if [[ "$_envowner" != root || "$_envmode" != 600 ]]; then
    echo "[!] ${UPSTREAM_KEYS_FILE}: want root-owned mode 600, got ${_envowner} ${_envmode}" >&2
    echo "    sudo chown root:root ${UPSTREAM_KEYS_FILE} && sudo chmod 600 ${UPSTREAM_KEYS_FILE}" >&2
    exit 1
  fi
  # Parsed, not sourced: this file holds data, and `source` would execute
  # whatever a fat-fingered edit left in it, as root.
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
# Names only, never values — this output ends up in terminals and logs.
if ((${#_kata_keys_found[@]})); then
  echo "[*] upstream keys: ${_kata_keys_found[*]}"
else
  echo "[*] upstream keys: none (API-key providers will 502 at the proxy)"
  echo "    put KEY=value lines in ${UPSTREAM_KEYS_FILE} (root:root, 0600)"
fi

# --- mitmproxy (rootful podman, --network=host) ---------------------------
if podman container exists "$PROXY_NAME"; then
  podman rm -f "$PROXY_NAME" >/dev/null
fi

# Run as uid 1000:1000 AND override the image entrypoint to exec mitmdump
# directly. The image's docker-entrypoint wrapper unconditionally su-execs
# down to the `mitmproxy` user; that setuid/setgid/setgroups switch needs
# CAP_SETUID/CAP_SETGID, which --cap-drop=ALL removes → "operation not
# permitted". (An earlier failure mode — usermod aborting on a failed stat
# of the 0700 CA dir — came from the same root entrypoint losing
# CAP_DAC_READ_SEARCH.) Bypassing the wrapper sidesteps both: mitmdump runs
# as uid 1000, which owns the CA dir (reads the key, writes its cert cache)
# and binds the unprivileged port 8080 with no caps. We omit --rm so a
# crashed container survives for `podman logs`.
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

# Wait for the bind (mitmdump's Python startup can take a few seconds the
# first time after a pull while bytecode is compiled).
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

# --- migration: stop a litellm container left by an older checkout --------
# The litellm service was deleted 2026-09-11 (its key swap moved into the
# mitmproxy addon). A container from a previous `kata up` would otherwise keep
# running and keep holding :4000, which no longer has an nft accept in front of
# it — reachable from the host, dead from the sandbox, and confusing from both.
if podman container exists agent-litellm 2>/dev/null; then
  podman rm -f agent-litellm >/dev/null
  echo "[-] removed the obsolete agent-litellm container"
fi

echo "[ok] net up — bridge=${BRIDGE} proxy=${HOST_IP}:${PROXY_PORT} (mitmproxy)"
echo "     allowlist profile: ${ALLOWLIST_PROFILE}  (kata up --profile NAME to change)"
