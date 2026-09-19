#!/usr/bin/env bash
# tests/gate.sh — the LIVE egress gate, exercised from the host with no
# privilege at all. Needs `kata up` to have run; skips politely otherwise.
#
# Why a third suite. unit.sh tests pure functions, guards.sh tests refusals that
# need root. These need neither — they need a running proxy, and they are the
# only tests here that exercise the addon as deployed rather than as imported.
# proxy/mitmproxy/test_addon.py covers the same logic with mitmproxy stubbed,
# which is faster and offline; it cannot tell you that the file in
# /etc/agent-proxy is the file in the repo, or that the container was restarted
# after you edited it. That gap is exactly what shipped the bug below.
#
# Invariants — D for Destination:
#   D0  the gate is live and denies an unallowed host          (positive control)
#   D1  a spoofed Host: does not launder a denied destination
#   D2  a foreign Host: on an ALLOWED destination is refused too
#   D3  and nothing is delivered — the 403 is not the property, non-arrival is
#   D4  a CONNECT to a denied host is refused at the tunnel
#   D5  a CONNECT to an allowed host reaches upstream resolution (control: the
#       tunnel gate is not blanket-denying TLS)
#   D6  a write to a read-only pinned host is refused
#   D7  the gate names the profile it is enforcing, and it is a real one
#   D8  a host outside the DEPLOYED profile is denied (asks the gate which
#       profile it runs, then checks that profile's own boundary)
#   D9  a POST to a provider API is NOT refused (control for the read-only pins:
#       a chat completion is a POST, so pinning those would break the sandbox)
#
# THE BUG THESE EXIST FOR (2026-09-13). addon.py judged `request.pretty_host`,
# which prefers the client's `Host` header — so one curl flag reached ANY
# destination, including host loopback, the LAN and the tailnet (the proxy runs
# --network=host, and agent_isolate cannot fence a socket that belongs to
# mitmproxy rather than to the guest). `podman logs` cheerfully printed
# `ALLOW pypi.org GET /exfil-proof` for traffic that went to 127.0.0.1: the
# monitor was reading the same field the attacker controlled. Every structural
# check was green throughout.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"
# shellcheck source=config.sh
source "${ROOT}/config.sh"

ALL_IDS=(D0 D1 D2 D3 D4 D5 D6 D7 D8 D9)
PROXY="http://${HOST_IP}:${PROXY_PORT}"
CATCH_PORT=18081

section "live egress gate (D)"

STATE="$(proxy_state)"
if [[ "$STATE" != ok ]]; then
  for i in "${ALL_IDS[@]}"; do skip "$i" "live egress gate" "proxy is '${STATE}'; run: sudo kata up"; done
  report
  exit $?
fi

# What the gate said, reduced to two words so a test reads as an assertion rather
# than a diff of HTML: "<code> <which refusal>".
verdict() { # verdict <curl args…> -> "<http code> <mismatch|allowlist|other>"
  local body code
  body="$(curl -s --max-time 8 -x "$PROXY" -w '\n%{http_code}' "$@" 2>/dev/null)"
  code="${body##*$'\n'}"
  case "$body" in
  *"host mismatch"*) echo "${code} mismatch" ;;
  *"read-only"*) echo "${code} readonly" ;;
  *allowlist*) echo "${code} allowlist" ;;
  *) echo "${code} other" ;;
  esac
}

# The proxy's own answer to a CONNECT, which is NOT $http_code: a refused tunnel
# leaves curl with no response to the actual request, so %{http_code} is 000 and
# the interesting status is only in the trace.
tunnel_code() { # tunnel_code <https url> -> the proxy's status line code
  curl -sv --max-time 10 -x "$PROXY" "$1" -o /dev/null 2>&1 |
    sed -n 's/^< HTTP\/1\.1 \([0-9][0-9][0-9]\).*/\1/p' | head -1
}

is D0 "an unallowed host is denied (gate live)" "403 allowlist" "$(verdict http://kata-status.invalid/)"

is D1 "a spoofed Host does not launder a denied destination" "403 mismatch" \
  "$(verdict -H 'Host: pypi.org' http://kata-status.invalid/)"

# Not symmetric with D1, and not redundant: judging the real destination alone
# would let this through. Two names can share an IP, and a shared origin routes
# on the Host header we would have ignored.
is D2 "a foreign Host on an allowed destination is refused" "403 mismatch" \
  "$(verdict -H 'Host: attacker.example' http://pypi.org/simple/)"

# D3: the 403 is not the invariant. NON-ARRIVAL is. A listener on loopback is
# the only thing that can tell the two apart, and the direct-reachability check
# below it is what stops "nothing arrived" from also being true of a dead
# listener.
if command -v python3 >/dev/null; then
  python3 -m http.server --bind 127.0.0.1 "$CATCH_PORT" >"${TMPDIR:-/tmp}/kata-catch.$$" 2>&1 &
  CATCH=$!
  for _ in $(seq 1 300); do
    if listens 127.0.0.1 "$CATCH_PORT"; then break; fi
  done
  if ! listens 127.0.0.1 "$CATCH_PORT"; then
    skip D3 "nothing is delivered to host loopback" "listener did not bind"
  elif ! curl -s -o /dev/null --max-time 5 "http://127.0.0.1:${CATCH_PORT}/reachable"; then
    skip D3 "nothing is delivered to host loopback" "listener unreachable even directly"
  else
    verdict -H 'Host: pypi.org' "http://127.0.0.1:${CATCH_PORT}/exfil-proof" >/dev/null
    # The direct hit above is in the log; the proxied one must not be.
    if grep -q exfil-proof "${TMPDIR:-/tmp}/kata-catch.$$"; then
      is D3 "nothing is delivered to host loopback" "no /exfil-proof" "DELIVERED"
    else
      is D3 "nothing is delivered to host loopback" "no /exfil-proof" "no /exfil-proof"
    fi
  fi
  kill "$CATCH" 2>/dev/null
  wait "$CATCH" 2>/dev/null
  rm -f "${TMPDIR:-/tmp}/kata-catch.$$"
else
  skip D3 "nothing is delivered to host loopback" "no python3 for the listener"
fi

is D4 "a CONNECT to a denied host is refused at the tunnel" "403" \
  "$(tunnel_code https://kata-status.invalid/)"

# D5 is the control for D4: without it, a gate that refused every CONNECT would
# pass D4 and break all TLS. 502 = allowed through the tunnel gate, then failed
# upstream (the host does not resolve) — which is also true offline, so this
# stays a network-free test.
is D5 "a CONNECT to an allowed host is not refused (control)" "502" \
  "$(tunnel_code https://nonexistent.astral.sh/)"

# D6: pypi.org is on every profile and pinned to reads, so this needs no network
# (the refusal happens before any upstream connection) and no assumption about
# which profile is deployed.
is D6 "a write to a read-only host is refused" "403 readonly" \
  "$(verdict -X POST http://pypi.org/upload)"

# D7 reads the policy out of the running gate rather than out of config.sh —
# the whole reason the profile is in the 403 body. An empty answer here would
# mean the deployed addon predates profiles.
DEPLOYED="$(proxy_profile)"
case "$DEPLOYED" in
swe | research | local) is D7 "the gate names its profile" "known" "known" ;;
"") is D7 "the gate names its profile" "known" "empty (addon predates profiles: kata up)" ;;
*) is D7 "the gate names its profile" "known" "unknown profile '${DEPLOYED}'" ;;
esac

# D8 asks the deployed profile what it should do, then checks it does it — so it
# is meaningful under any profile instead of hardcoding one. huggingface.co is
# the discriminator: in `models`, which only `research` composes.
case "$DEPLOYED" in
swe | local)
  is D8 "a host outside the deployed profile is denied" "403 allowlist" \
    "$(verdict http://huggingface.co/x)"
  ;;
research)
  # Asserting the opposite here would mean a real request to huggingface.co, and
  # a network-dependent test in a suite that has none. The negative case is what
  # carries the meaning and it is covered whenever the gate runs swe or local.
  skip D8 "a host outside the deployed profile is denied" \
    "models IS in research; re-run under swe to exercise this"
  ;;
*) skip D8 "a host outside the deployed profile is denied" "unknown deployed profile" ;;
esac

# D9 is the control that keeps the pins honest: a chat completion is a POST, so
# the provider APIs must stay unpinned. Any answer that is not OUR refusal
# passes, which also makes it work offline (curl reports 000 and D0 has already
# proved the gate is alive).
if [[ "$DEPLOYED" == local ]]; then
  skip D9 "POST to a model API is not refused" "the local profile has no provider hosts, by design"
else
  D9_GOT="$(verdict -X POST http://api.anthropic.com/v1/messages)"
  case "$D9_GOT" in
  *allowlist* | *readonly* | *mismatch*) is D9 "POST to a model API is not refused" "not refused" "$D9_GOT" ;;
  *) is D9 "POST to a model API is not refused" "not refused" "not refused" ;;
  esac
fi

report
