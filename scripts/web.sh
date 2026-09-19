#!/usr/bin/env bash
# web.sh — local web tooling for the sandbox. Currently: searxng (metasearch).
#
# Why local: `enap search` points at the VPS over tailscale by default, which
# the sandbox cannot and must not reach. Running searxng on the bridge keeps the
# capability and takes the tailnet out of the picture entirely — the agent's
# search path terminates on this host.
#
# Opt-in, not part of `kata up`: a session that doesn't search shouldn't have a
# metasearch engine listening. `kata down` stops it regardless, since it
# publishes on $HOST_IP and net-down.sh deletes that address with the bridge.
#
# Threat note (read before adding a second service here). searxng runs with
# --network=host, like mitmproxy. That is defensible *here* because
# the agent controls the query string, never the destination: searxng only ever
# talks to its own configured engines. Do NOT reuse this shape for firecrawl —
# there the agent picks the URL, and host netns would hand it a read primitive
# against host loopback, the LAN and the tailnet.
#
# Subcommands: up | down | status
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

SEARXNG_SETTINGS="${SEARXNG_ETC_DIR}/settings.yml"
SEARXNG_SECRET_FILE="${SEARXNG_ETC_DIR}/secret_key"
SEARXNG_URL="http://${HOST_IP}:${SEARXNG_PORT}"

die() {
  echo "web: $*" >&2
  exit 1
}

listening() {
  ss -lnt "sport = :${SEARXNG_PORT}" 2>/dev/null | grep -q "${HOST_IP}:${SEARXNG_PORT}"
}

cmd_up() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 up) — rootful podman + /etc"

  # searxng binds $HOST_IP directly (--network=host), so the bridge must exist.
  ip -o addr show to "${HOST_IP}/32" 2>/dev/null | grep -q . ||
    die "$HOST_IP is not on this host — bring the bridge up first: kata up"

  # The sandbox reaches this port through rules net-up.sh installs from
  # $SANDBOX_HOST_PORTS. If searxng was added to that list after the last
  # `kata up`, the port is open on the host but closed to the guest — which
  # looks like a searxng bug from inside. Catch it here instead.
  if ! nft list chain inet agent_vm input 2>/dev/null | grep -q "dport ${SEARXNG_PORT}"; then
    echo "[!] no nft accept for ${SEARXNG_PORT} — the sandbox will not reach searxng."
    echo "    re-run 'sudo ${HERE}/net-up.sh' (it opens \$SANDBOX_HOST_PORTS)."
  fi

  install -d -m 0755 "$SEARXNG_ETC_DIR"
  # 0644: the container runs as uid $SEARXNG_UID and must read this. It holds no
  # secret — that comes from $SEARXNG_SECRET below.
  install -m 0644 "${REPO_ROOT}/web/searxng/settings.yml" "$SEARXNG_SETTINGS"

  # Per-deployment secret, same shape as the mitmproxy CA: generated on first
  # up, never committed, never in the settings file. searxng exits(1) if
  # server.secret_key is still the upstream placeholder, so this is required,
  # not decorative.
  if [[ ! -s "$SEARXNG_SECRET_FILE" ]]; then
    (
      umask 077
      openssl rand -hex 32 >"$SEARXNG_SECRET_FILE"
    )
    echo "[+] generated per-deployment searxng secret at $SEARXNG_SECRET_FILE"
  fi
  chmod 0600 "$SEARXNG_SECRET_FILE"

  if podman container exists "$SEARXNG_NAME"; then
    podman rm -f "$SEARXNG_NAME" >/dev/null
  fi

  # --user: the image declares no USER, so the entrypoint and granian would
  #   otherwise run as container root. 977 is the image's own searxng account.
  # --image-volume=ignore: the image declares /etc/searxng + /var/cache/searxng
  #   as VOLUMEs; without this podman creates anonymous volumes for them on
  #   every run. Neither needs to be writable — the entrypoint only stats them.
  # --tmpfs /tmp: searxng's ExpireCacheSQLite defaults its DB to
  #   /tmp/sxng_cache_DATA_CACHE.db and connects at startup, so a read-only /tmp
  #   is a hard boot failure.
  # GRANIAN_HOST/PORT: the WSGI server reads these, not searxng's
  #   server.bind_address. The image default is `::` — with --network=host that
  #   would publish the agent's search engine on every host interface.
  # No --rm: keep a crashed container around for `podman logs`.
  podman run -d \
    --name "$SEARXNG_NAME" \
    --network=host \
    --user "${SEARXNG_UID}:${SEARXNG_UID}" \
    --read-only \
    --image-volume=ignore \
    --security-opt=no-new-privileges \
    --cap-drop=ALL \
    --tmpfs /tmp:size=64M,mode=1777 \
    -v "${SEARXNG_SETTINGS}":/etc/searxng/settings.yml:ro,Z \
    -e "GRANIAN_HOST=${HOST_IP}" \
    -e "GRANIAN_PORT=${SEARXNG_PORT}" \
    -e "SEARXNG_SECRET=$(cat "$SEARXNG_SECRET_FILE")" \
    "$SEARXNG_IMAGE" >/dev/null

  for _ in $(seq 1 100); do
    listening && break
    sleep 0.3
  done
  listening || {
    echo "searxng failed to bind ${HOST_IP}:${SEARXNG_PORT}"
    echo "--- podman logs ${SEARXNG_NAME} (last 60 lines) ---"
    podman logs --tail 60 "$SEARXNG_NAME" 2>&1 || true
    echo "--- container left running for inspection (podman rm -f ${SEARXNG_NAME}) ---"
    exit 1
  }

  smoke_json
  echo "[ok] searxng up: ${SEARXNG_URL} — in the sandbox: SEARXNG_URL=${SEARXNG_URL}"
}

# The JSON API is off in upstream defaults and `enap` speaks only JSON, so a
# working HTML UI proves nothing. Assert the format is actually served: searxng
# answers 403 for a format that isn't in search.formats.
smoke_json() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 20 \
    "${SEARXNG_URL}/search?q=katastrophe&format=json" || echo 000)"
  case "$code" in
  200) echo "[+] JSON API answering (GET /search?format=json → 200)" ;;
  403) die "JSON API refused (403) — search.formats in web/searxng/settings.yml lost 'json'" ;;
  000) die "no answer from ${SEARXNG_URL}/search — check 'podman logs ${SEARXNG_NAME}'" ;;
  *) die "unexpected HTTP $code from ${SEARXNG_URL}/search?format=json" ;;
  esac
}

cmd_down() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 down)"
  podman rm -f "$SEARXNG_NAME" 2>/dev/null >/dev/null || true
  echo "[-] searxng stopped"
}

cmd_status() {
  local state="absent"
  if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
    state="$(sudo -n podman inspect -f '{{.State.Status}}' "$SEARXNG_NAME" 2>/dev/null || echo absent)"
  else
    state="(needs sudo to read rootful podman)"
  fi
  echo "  container $SEARXNG_NAME  $state"
  echo "  settings  $SEARXNG_SETTINGS"
  echo "  secret    $([[ -s $SEARXNG_SECRET_FILE ]] && echo present || echo MISSING) ($SEARXNG_SECRET_FILE)"
  echo "  listening $(ss -lnt "sport = :${SEARXNG_PORT}" 2>/dev/null | awk 'NR>1 {print $4}' | paste -sd, - || true)"
  if listening; then
    echo "  json api  HTTP $(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 20 \
      "${SEARXNG_URL}/search?q=katastrophe&format=json" || echo 000)"
  fi
  echo "  guest env SEARXNG_URL=${SEARXNG_URL}"
}

sub="${1:-}"
shift || true
case "$sub" in
up) cmd_up "$@" ;;
down) cmd_down "$@" ;;
status) cmd_status "$@" ;;
-h | --help | "")
  echo "usage: web {up|down|status}"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
