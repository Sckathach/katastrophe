#!/usr/bin/env bash
# web.sh — local searxng for the sandbox (`kata web up|down|status`). Opt-in:
# a session that does not search should not have it listening. `kata down`
# stops it too (it binds $HOST_IP, which goes with the bridge).
#
# --network=host is acceptable only because the agent controls the query, never
# the destination. Do NOT reuse this shape for anything where the agent picks
# the URL (firecrawl): host netns would be a read primitive against loopback,
# the LAN and the tailnet.
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
  [[ $EUID -eq 0 ]] || die "run as root (kata web up) — rootful podman + /etc"

  ip -o addr show to "${HOST_IP}/32" 2>/dev/null | grep -q . ||
    die "$HOST_IP is not on this host — bring the bridge up first: kata up"

  # Rules are inserted at `kata up` time; otherwise this reads as a searxng bug
  # from inside the guest.
  if ! nft list chain inet agent_vm input 2>/dev/null | grep -q "dport ${SEARXNG_PORT}"; then
    echo "[!] no nft accept for ${SEARXNG_PORT}, the sandbox will not reach searxng — fix: kata up"
  fi

  install -d -m 0755 "$SEARXNG_ETC_DIR"
  # 0644: the container user must read it; the secret is not in it.
  install -m 0644 "${REPO_ROOT}/web/searxng/settings.yml" "$SEARXNG_SETTINGS"

  # Per-deployment, never committed. searxng refuses to start on the placeholder.
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

  # --user: the image declares no USER (else container root).
  # --image-volume=ignore: no anonymous volumes for the image's VOLUMEs.
  # --tmpfs /tmp: its cache DB lives there; read-only /tmp fails the boot.
  # GRANIAN_HOST: the server's default `::` would, with host netns, publish on
  #   every host interface.
  # No --rm: a crashed container keeps its logs.
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

# `enap` speaks only JSON, which upstream disables: a working HTML UI proves
# nothing. searxng answers 403 for a format not in search.formats.
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
  [[ $EUID -eq 0 ]] || die "run as root (kata web down)"
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
  echo "usage: kata web {up|down|status}"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
