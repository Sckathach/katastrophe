#!/usr/bin/env bash
# tests/run.sh — run every suite, print one summary, exit non-zero if anything
# failed. `kata test` is this.
#
# What runs where, because "run the tests" is three different things here:
#
#   tests/unit.sh     pure functions in scripts/lib.sh. No root, no network, no
#                     VM. Under a second — run it on every edit.
#   tests/guards.sh   the real launch refusals in vm.sh. Needs root; skips
#                     politely without it. Seconds, boots nothing.
#   tests/host.sh     host posture: qemu's uid, device ACLs, CA modes, bridge
#                     bindings. No root, no VM — every row SKIPS when the thing
#                     it inspects is not running, which is the point.
#   tests/gate.sh     the egress gate AS DEPLOYED — needs `kata up`, needs no
#                     privilege. The only suite that can tell you the addon in
#                     /etc/agent-proxy is the addon in the repo.
#   proxy/mitmproxy/  the addon's two properties, with mitmproxy stubbed: the
#     test_addon.py   gate judges the destination and not the Host header, and
#                     the key swap fires IFF the client presented the sentinel.
#                     Neither can be verified by booting the VM — both bad cases
#                     (traffic delivered to a host the log did not name; an OAuth
#                     session silently moved onto a metered key) look exactly
#                     like success.
#
# NOT run from here, and it matters that you know why:
#
#   scripts/audit-egress.sh  runs INSIDE a guest (T1–T4: no DNS, no direct TCP,
#                            no raw sockets, proxy reachable). Those are the
#                            invariants that can only be proven from the agent's
#                            vantage point — the host cannot answer them for it.
#                            `kata ssh` then `audit-egress.sh`. Everything else
#                            that needs a guest, a second machine or a reboot is
#                            in tests/MANUAL.md — a short, honest list rather
#                            than a table pretending to be coverage.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

fails=0
run() { # run <label> <cmd…>
  printf '\n\033[1m== %s\033[0m\n' "$1"
  shift
  if ! "$@"; then fails=$((fails + 1)); fi
}

run "unit — lib.sh pure functions" "${HERE}/unit.sh"
run "guards — vm.sh launch refusals" "${HERE}/guards.sh"
run "host — posture that needs no guest" "${HERE}/host.sh"
run "gate — the live egress gate" "${HERE}/gate.sh"

if command -v python3 >/dev/null; then
  run "addon — key swap fires only on the sentinel" \
    python3 "${ROOT}/proxy/mitmproxy/test_addon.py"
else
  printf '\n\033[33m== addon: skipped (no python3)\033[0m\n'
fi

# Syntax is not a test, but a suite that passes while a script cannot parse is
# worse than useless, and this costs milliseconds.
run "syntax — bash -n over every script" bash -c "
  cd '${ROOT}' && rc=0
  for f in kata config.sh scripts/*.sh tests/*.sh; do
    bash -n \"\$f\" || { echo \"  syntax error: \$f\"; rc=1; }
  done
  if [[ \$rc -eq 0 ]]; then echo '  all scripts parse'; fi
  exit \$rc"

printf '\n'
if ((fails)); then
  printf '\033[31m%d suite(s) failed\033[0m\n' "$fails"
  exit 1
fi
printf '\033[32mall suites passed\033[0m\n'
printf '\033[2min-guest invariants (T1–T4) are not covered here: kata ssh, then audit-egress.sh\033[0m\n'
printf '\033[2mthe rest of what a suite cannot reach: tests/MANUAL.md\033[0m\n'
