#!/usr/bin/env bash
# tests/host.sh — host-state invariants that need neither root nor a guest.
#
# These came out of docs/testing/security-invariants.md (deleted 2026-09-13), a
# table of ~40 claims with a "how to check" column you were supposed to run by
# hand. Nobody ran it, so it rotted — it still described `kata verify`, litellm
# and `--workspace` weeks after all three were gone. The rule that replaced it:
# **an invariant with no runnable check is a claim.** These are the rows that
# turned out to be one `ss`/`stat`/`getfacl` away from being real tests. The rest
# are in tests/MANUAL.md, honestly labelled as manual.
#
# Invariants — H for Host posture (P is taken by unit.sh's state_field test;
# an ID has to name exactly one invariant or the suites stop being greppable):
#   H1  qemu runs as the agent uid, so an escape lands soft  (threat: qemu-uid-drop)
#   H2  no ACL hands the agent uid the NVIDIA device nodes   (threat: kernel-cve)
#   H3  the mitmproxy CA private key is 0600 and host-side   (threat: mitm-ca)
#   H4  the public cert is world-readable (positive control for H3)
#   G4  the git daemon is bridge-bound, never 0.0.0.0        (threat: git-interchange)
#   S1  searxng is bridge-bound, never 0.0.0.0               (threat: searxng-host-netns)
#
# Every one of these SKIPS when the thing it inspects is not running, and that
# is deliberate: a green row for a service that is down is the `podman container
# exists` mistake in a different costume.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=tests/lib.sh
source "${HERE}/lib.sh"
# shellcheck source=config.sh
source "${ROOT}/config.sh"

section "host posture (H, G4, S1)"

# H1. The vCPU thread is what a hypervisor escape rides. `root` here means qemu
# older than 8.0 (no -run-with user=) or someone set ALLOW_QEMU_ROOT=1.
QEMU_USER="$(ps -o user= -C qemu-system-x86_64 2>/dev/null | tr -d ' ' | head -1)"
if [[ -z "$QEMU_USER" ]]; then
  skip H1 "qemu runs as the agent uid, not root" "no VM session running"
else
  is H1 "qemu runs as the agent uid, not root" "$AGENT_USER" "$QEMU_USER"
fi

# H2. disk.sh used to setfacl -m u:agent:rw /dev/nvidia* on every mount so the
# rootless GPU container could reach the driver. That runtime is gone and the
# process running as uid 1001 now is qemu after its drop — so those ACLs were
# handing an escaped qemu direct ioctl access to the NVIDIA driver, i.e. exactly
# the ring-0 surface VFIO removes. If this ever fails, find out who re-added it.
if ! compgen -G '/dev/nvidia*' >/dev/null && ! compgen -G '/dev/dri/*' >/dev/null; then
  skip H2 "no ACL grants the agent uid the GPU device nodes" "no device nodes (sandbox GPU mode?)"
elif ! command -v getfacl >/dev/null; then
  skip H2 "no ACL grants the agent uid the GPU device nodes" "no getfacl"
else
  GRANTS="$(getfacl -sp /dev/nvidia* /dev/dri/* 2>/dev/null |
    grep -c "^user:${AGENT_USER}:" || true)"
  is H2 "no ACL grants the agent uid the GPU device nodes" "0" "$GRANTS"
fi

# H3/H4. The CA private key can mint a valid leaf for any allowlisted host as far
# as the guest is concerned, so its mode is load-bearing; the public cert must be
# readable by everything that needs to trust it. Both stats are unprivileged: the
# CA dir is traversable by the uid that owns it, which is the one running this.
if [[ ! -e "$PROXY_CA_PEM" ]]; then
  skip H3 "the CA private key is 0600" "no CA yet (run: sudo kata up)"
  skip H4 "the public cert is world-readable" "no CA yet (run: sudo kata up)"
else
  is H3 "the CA private key is 0600" "600" "$(stat -c '%a' "$PROXY_CA_PEM" 2>/dev/null)"
  # Not merely the inverse of H3: it is the control that says H3 passed because
  # the mode is right, not because the whole tree is unreadable.
  if [[ -e "$PROXY_CA_CERT_PUB" ]]; then
    is H4 "the public cert is world-readable" "644" "$(stat -c '%a' "$PROXY_CA_CERT_PUB" 2>/dev/null)"
  else
    skip H4 "the public cert is world-readable" "not published yet"
  fi
fi

# G4/S1. Both services run with host networking, so the bind address is the only
# thing standing between "the agent can search" and "everyone on the LAN and the
# tailnet can". `listens` greps ss for the exact ip:port, so a 0.0.0.0 bind fails
# the first check and passes the second.
for pair in "G4|git daemon|${GIT_PORT}" "S1|searxng|${SEARXNG_PORT}"; do
  IFS='|' read -r id name port <<<"$pair"
  if ! ss -lnt "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
    skip "$id" "${name} is bound to the bridge, never 0.0.0.0" "nothing on :${port}"
  elif listens "$HOST_IP" "$port"; then
    is "$id" "${name} is bound to the bridge, never 0.0.0.0" "bridge-only" "bridge-only"
  else
    is "$id" "${name} is bound to the bridge, never 0.0.0.0" "bridge-only" \
      "$(ss -lnt "sport = :${port}" | awk 'NR>1{print $4}' | tr '\n' ' ')"
  fi
done

report
