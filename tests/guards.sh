#!/usr/bin/env bash
# tests/guards.sh — the launch-time refusals in scripts/vm.sh, exercised for
# real. NEEDS ROOT (vm.sh refuses to run otherwise) and skips politely without
# it: a suite that fails for lack of a password trains you to ignore it.
#
# Nothing here boots a guest, and that is enforced rather than hoped for: every
# invocation carries a stopper and a timeout. See THE STOPPER below — it is the
# most important comment in this file.
#
# Each failure is faked by overriding ONE constant through `env VAR=…`, which is
# also THE RULE in miniature: an `export` would not survive into a privileged
# child, and every test here would then pass for the wrong reason — the guard
# never fires, the command fails for some other cause, and only the pattern match
# in `deny` catches it.
#
# NOT `sudo env …`, and this cost a run: this script is already root, and **sudo
# inside a sudo'd process rewrites SUDO_USER to root**. $HOST_USER is derived
# from SUDO_USER, so the nested call flipped it from you to root and
# require_storage refused the temp bases dir ("owned by 'sckathach', expected
# 'root'") before any guard under test could run. Worth remembering outside the
# tests too: anything that re-sudoes from a root context loses the invoking user,
# which is exactly what save_base needs to chown a new base back to you.
#
# Invariants:
#   E1  no bridge                    → refuse
#   E2  no agent_vm table            → refuse (not automated; see the skip)
#   E3  proxy port with nothing on it → refuse
#   E4  proxy answers, but not 403   → refuse. The sandbox would otherwise have
#                                      UNFILTERED egress with every structural
#                                      check still green.
#   E5  the live gate denies an unallowed host (positive control)
#   B1  base trusting a different mitmproxy CA → refuse
#   B2  --to onto a stale base → refuse; --force overrides; booting it read-only
#       is NOT refused
#   W1  a home that is not agent-owned → refuse (the call site; the function
#       itself is unit-tested)
#   W2  --rw under your home → refuse
#   W3  --ro under your home → permitted
#   W4  the agent uid cannot write $VM_BASES_DIR  (threat: base-poisoning)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"
# shellcheck source=config.sh
source "${ROOT}/config.sh"

VM="${ROOT}/scripts/vm.sh"
ALL_IDS=(E1 E2 E3 E4 E5 B1 B2 W1 W2 W3 W4 N1)

section "launch guards (E, B, W)"

if [[ $EUID -ne 0 ]]; then
  for i in "${ALL_IDS[@]}"; do skip "$i" "vm.sh launch guard" "re-run as: sudo tests/guards.sh"; done
  report
  exit $?
fi
if session_pid >/dev/null; then
  for i in "${ALL_IDS[@]}"; do skip "$i" "vm.sh launch guard" "a session is running; vm.sh refuses a second"; done
  report
  exit $?
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OWNER="${HOST_USER:-root}"

# A base that exists, is current, and is a real qcow2 — so any refusal can only
# come from the guard under test. $VM_BASES_DIR must be owned by you, which
# require_storage checks (threat: base-poisoning — vm.sh parses these as root).
BASES="${TMP}/bases"
mkdir -p "$BASES"
chown "$OWNER" "$TMP" "$BASES"
qemu-img create -f qcow2 "${BASES}/ok.qcow2" 64M >/dev/null
VM_BASES_DIR="$BASES" HOST_USER="$OWNER" base_meta_write ok build "" false

# A home vm.sh will accept: agent-owned. Prefer the real one; fall back to a
# temp dir, since what is under test here is the guards, not storage.
HOME_ARG="$MOUNT_HOME"
if [[ "$(stat -c %U "$MOUNT_HOME" 2>/dev/null)" != "$AGENT_USER" ]]; then
  HOME_ARG="${TMP}/home"
  mkdir -p "$HOME_ARG"
  chown "${AGENT_USER}:${AGENT_USER}" "$HOME_ARG"
fi

# THE STOPPER, and it is applied automatically — read this before adding a test.
#
# A guard test asserts that vm.sh refuses. If the guard does NOT fire, vm.sh
# carries on and BOOTS A GUEST, in the foreground, with its stdout captured by
# the harness: the suite hangs, and it hangs having done the exact thing the
# guard existed to prevent. That is not hypothetical — the first version of W2
# passed `--rw $HOME`, and $HOME inside a sudo'd script is /root while
# FORBIDDEN_WORKSPACE_PREFIX is /home/<you>, so nothing matched, nothing refused,
# and the test booted a VM with root's home mounted writable at /mnt/rw_1.
#
# So `vm()` injects `PROXY_PORT=9` unless the caller sets PROXY_PORT itself.
# Nothing listens on port 9, so the egress preflight always refuses — which is
# the LAST check before launch, hence a backstop for every guard upstream of it
# without changing which refusal fires first. A test can now fail, but it cannot
# start a guest. Do not remove it to "make a test more realistic": the realistic
# version of a failed guard test is a running VM.
STOPPER_VAR=PROXY_PORT
STOPPER_MSG="nothing is listening"

FROM_BASE=ok
vm() { # vm [VAR=VAL …] [-- extra vm.sh args …]
  local envs=() args=() have_stopper=false
  while (($#)); do
    case "$1" in
    --)
      shift
      args=("$@")
      break
      ;;
    *)
      if [[ "$1" == "${STOPPER_VAR}="* ]]; then have_stopper=true; fi
      envs+=("$1")
      shift
      ;;
    esac
  done
  if [[ "$have_stopper" != true ]]; then envs+=("${STOPPER_VAR}=9"); fi
  # HOST_USER is passed explicitly because vm.sh re-derives it from SUDO_USER,
  # which is not what we want in an already-root process (see the header).
  # Second backstop: `timeout` cannot wrap a shell function, so it goes here
  # rather than in the harness. A guard test should finish in well under a second;
  # anything that reaches 60s has started something, and failing beats hanging.
  timeout 60 env VM_BASES_DIR="$BASES" HOST_USER="$OWNER" "${envs[@]}" \
    "$VM" --home "$HOME_ARG" --from "$FROM_BASE" "${args[@]}"
}

section "egress preflight (E)"

deny E1 "a missing bridge is refused" "bridge .* is missing" -- \
  vm BRIDGE=kata-no-such-br0

# E2 is deliberately NOT automated. Faking a missing agent_vm table means
# deleting the live one (kata down), which is destructive to whatever else is
# using the sandbox — and a test that tears down your network to prove a point
# is a test you disable. Covered by hand: `sudo kata down && sudo kata vm`.
skip E2 "a missing agent_vm table is refused" "would require tearing down the live gate"

deny E3 "a proxy port with nothing on it is refused" "nothing is listening" -- \
  vm PROXY_PORT=9

# E4 is the one a naive test gets wrong: pointing at a CLOSED port only proves
# E3 again. It needs something that genuinely speaks HTTP on the bridge IP and
# answers anything other than 403 — then vm.sh must refuse, because whatever
# that is, it is not our allowlist.
if command -v python3 >/dev/null; then
  python3 -m http.server --bind "$HOST_IP" 18080 >/dev/null 2>&1 &
  DECOY=$!
  # Bounded spin rather than sleep: ss is the throttle, and it is bound in ~100ms.
  for _ in $(seq 1 300); do
    if listens "$HOST_IP" 18080; then break; fi
  done
  if listens "$HOST_IP" 18080; then
    deny E4 "a proxy that answers but is not 403 is refused" "expected 403" -- \
      vm PROXY_PORT=18080
  else
    skip E4 "a proxy that answers but is not 403 is refused" "decoy server did not bind"
  fi
  kill "$DECOY" 2>/dev/null
  wait "$DECOY" 2>/dev/null
else
  skip E4 "a proxy that answers but is not 403 is refused" "no python3 for the decoy"
fi

# E5, the positive control, and it is not optional: without it every deny above
# could be passing because vm.sh refuses everything on this host. Same function
# the preflight calls, so this is the real gate answering.
is E5 "the live gate denies an unallowed host (403)" "ok" "$(proxy_state)"

section "base integrity (B)"

# B1: faked from the HOST side by pointing the fingerprint at another file —
# equivalent to net-up.sh having regenerated the CA under a base built against
# the old one, which is exactly how this happens in practice.
deny B1 "a base trusting a different CA is refused" "different mitmproxy CA" -- \
  vm PROXY_CA_CERT_PUB=/etc/hostname PROXY_CA_CERT=/etc/hostname
allow B1 "a base trusting the current CA is accepted (positive control)" -- \
  bash -c "cd '${ROOT}' && source ./config.sh && VM_BASES_DIR='${BASES}' &&
           [[ -n \"\$(ca_fingerprint)\" && \"\$(base_ca ok)\" == \"\$(ca_fingerprint)\" ]]"

# B2: move the parent on under a child, then try to bake the child.
qemu-img create -f qcow2 "${BASES}/child.qcow2" 64M >/dev/null
VM_BASES_DIR="$BASES" HOST_USER="$OWNER" base_meta_write child bake ok false
VM_BASES_DIR="$BASES" HOST_USER="$OWNER" base_meta_write ok build "" false
FROM_BASE=child

deny B2 "--to onto a stale base is refused" "stale base" -- \
  vm -- --to child
says B2 "--force overrides it, as a warning" "warning:.*stale base" -- \
  vm -- --to child --force
permits B2 "booting a stale base without --to is not refused" "stale base" "$STOPPER_MSG" -- \
  vm
FROM_BASE=ok

section "host-path foot-guns (W)"

# The pair that turns the --ro exemption into a tested decision rather than a
# comment: --rw under your home is refused, --ro under it is not. virtiofsd
# reads your home as root, the guest sees only the subtree, and an escape lands
# as the agent uid, which agent_isolate already fences.
# $FORBIDDEN_WORKSPACE_PREFIX, not $HOME: sudo sets HOME=/root, which is not
# under /home/<you> and therefore never matched the guard — the test asserted a
# refusal that could not happen. Ask the code which prefix it defends.
# W1 is unit-tested in unit.sh (require_storage is a pure function); this is the
# same invariant at its real CALL SITE, which is a different claim — that vm.sh
# actually consults it before doing anything. MOUNT_HOME has to move with --home,
# because require_storage only demands an owner for paths that ARE a storage root.
BAD_HOME="${TMP}/root-owned-home"
mkdir -p "$BAD_HOME" # left root-owned on purpose
# The override has to actually take effect, and on this machine it once did not:
# config.local.sh held a bare `MOUNT_HOME=/mnt/agent-home`, which beats the
# environment because it is sourced FIRST. vm.sh then ran against the real home
# — agent-owned, perfectly valid — sailed past this guard and died at the
# stopper instead. Nothing was wrong with the guard; the test could not reach it.
# So check the premise and skip loudly rather than report a confusing failure.
# (unit.sh C1 asserts the same contract directly.)
EFFECTIVE_HOME="$(env MOUNT_HOME="$BAD_HOME" bash -c "cd '${ROOT}' && source ./config.sh && printf '%s' \"\$MOUNT_HOME\"")"
if [[ "$EFFECTIVE_HOME" != "$BAD_HOME" ]]; then
  skip W1 "vm.sh refuses a home that is not agent-owned" \
    "config.local.sh hard-assigns MOUNT_HOME; use MOUNT_HOME=\"\${MOUNT_HOME:-...}\""
else
  deny W1 "vm.sh refuses a home that is not agent-owned" "owned by|expected" -- \
    vm MOUNT_HOME="$BAD_HOME" -- --home "$BAD_HOME"
fi

YOUR_HOME="${FORBIDDEN_WORKSPACE_PREFIX:-/home/${OWNER}}"
deny W2 "--rw under your home is refused" "refusing --rw" -- \
  vm -- --rw "${YOUR_HOME}/kata-test-path"
permits W3 "--ro under your home is NOT refused" "refusing --ro" "$STOPPER_MSG" -- \
  vm -- --ro "${YOUR_HOME}"

section "the agent cannot reach what protects you from it (W4)"

# threat: base-poisoning. vm.sh parses base qcow2s AS ROOT, and qcow2 parsing is
# a code-execution surface — so an agent-writable base is a host-code-exec path
# that needs no hypervisor escape at all. This is the single reason $VM_BASES_DIR
# is a sibling of the agent home and never inside it.
#
# `runuser`, not `sudo -u`: see the header. sudo from a root context rewrites
# SUDO_USER, and everything downstream that derives $HOST_USER from it then gets
# the wrong answer, several layers away from the cause.
if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
  skip W4 "the agent uid cannot write VM bases" "no ${AGENT_USER} user on this host"
elif [[ ! -d "$VM_BASES_DIR" ]]; then
  skip W4 "the agent uid cannot write VM bases" "${VM_BASES_DIR} does not exist yet"
else
  deny W4 "the agent uid cannot write VM bases" "permission denied" -- \
    runuser -u "$AGENT_USER" -- touch "${VM_BASES_DIR}/kata-test-poison.qcow2"
  # Positive control: the refusal above is about the AGENT, not about the
  # directory being unwritable by everyone (which would also pass, while meaning
  # bases are broken rather than protected).
  is W4 "...but you own it, so --to still works" "$OWNER" \
    "$(stat -c %U "$VM_BASES_DIR" 2>/dev/null)"
  rm -f "${VM_BASES_DIR}/kata-test-poison.qcow2"
fi

section "net-up.sh argument validation (N)"

# N1: a typo'd profile must be refused BEFORE any side effect. The first version
# validated just before starting the container, i.e. after the bridge, the nft
# tables and the CA — so `kata up --profile sew` left the host half-up: gate
# loaded, no proxy. Fail-closed, never dangerous, but a teardown for a typo.
#
# The post-condition is the real assertion, and it is only meaningful while a
# proxy is up: if validation moved back to the end, this test would TEAR DOWN the
# live gate to prove its point — so it checks that it did not.
if [[ "$(proxy_state)" == ok ]] && command -v python3 >/dev/null; then
  deny N1 "an unknown profile is refused" "unknown profile" -- \
    "${ROOT}/scripts/net-up.sh" --profile definitely-not-a-profile
  is N1 "...before touching the running gate" "ok" "$(proxy_state)"
  # Control: a real name gets past argument handling. It stops at --help rather
  # than running the setup, because a test suite has no business restarting your
  # network — so this proves parsing, not the validator (test_addon.py owns that
  # half). It is still worth having: the deny above would also pass if net-up.sh
  # refused everything, and the specific message pattern is what rules that out.
  says N1 "a valid profile parses (control)" "usage:" -- \
    "${ROOT}/scripts/net-up.sh" --profile swe --help
else
  # Without python3 net-up.sh cannot validate, so it would run the ENTIRE setup
  # with a bogus profile — the test would restart your network to check that it
  # does not. Skip, per the rule that a guard test must not be able to perform
  # the thing it is asserting against.
  skip N1 "net-up.sh refuses an unknown profile" "needs a live proxy + python3 to be safe"
fi

report
