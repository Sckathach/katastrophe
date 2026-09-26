#!/usr/bin/env bash
# doctor.sh — `kata doctor [--gpu]`: can this machine do it? Run once per
# machine, so it may prompt. Exit code = number of hard failures.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

DOCTOR_FAILS=0
need() { # $1=binary $2=install hint
  local p
  if p="$(command -v "$1" 2>/dev/null)"; then
    ok "$1 (${p})"
  else
    err "$1 not found — install $2"
    DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
  fi
}
want() { # soft version of need()
  local p
  if p="$(command -v "$1" 2>/dev/null)"; then ok "$1 (${p})"; else warn "$1 not found — $2"; fi
}
hard() { # $1=0|1 pass $2=msg-ok ("" = already reported, print nothing) $3=msg-fail
  if (($1)); then
    if [[ -n "$2" ]]; then ok "$2"; fi
  else
    err "$3"
    DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
  fi
}

cmd_doctor() {
  local gpu=false
  [[ "${1:-}" == "--gpu" ]] && gpu=true

  echo "runtime (qemu/KVM VM on the host bridge):"
  if [[ -w /dev/kvm ]]; then
    ok "/dev/kvm accessible"
  elif [[ -e /dev/kvm ]]; then
    hard 0 "" "/dev/kvm present but not writable (add yourself to the 'kvm' group)"
  else
    hard 0 "" "/dev/kvm missing (enable VT-x/AMD-V in firmware, load the kvm module)"
  fi
  need qemu-system-x86_64 "qemu / qemu-system-x86 / qemu-kvm"
  need qemu-img "qemu-img / qemu-utils"
  need nft nftables
  need podman "podman (runs the mitmproxy container)"
  need git "git (project interchange + git daemon)"
  need jq "jq (base metadata, session state)"

  # Same three places vm.sh searches.
  local v found=0
  for v in /usr/lib/virtiofsd /usr/libexec/virtiofsd "$(command -v virtiofsd 2>/dev/null || true)"; do
    if [[ -n "$v" && -x "$v" ]]; then
      ok "virtiofsd (${v})"
      found=1
      break
    fi
  done
  hard "$found" "" "virtiofsd not found (looked in /usr/lib, /usr/libexec, PATH)"

  local got
  got="$(id -u "$AGENT_USER" 2>/dev/null || true)"
  if [[ "$got" == "$AGENT_UID" ]]; then
    ok "user '${AGENT_USER}' exists (uid ${got})"
  elif [[ -n "$got" ]]; then
    hard 0 "" "user '${AGENT_USER}' has uid ${got}, expected ${AGENT_UID} (set AGENT_UID, or recreate the user)"
  else
    hard 0 "" "user '${AGENT_USER}' missing — sudo useradd -u ${AGENT_UID} -m ${AGENT_USER}"
  fi

  # Allowed to prompt: "unknown" is useless in a preflight. Separate "not
  # loaded" (nft's own error, a real failure) from "sudo declined" (a `sudo:`
  # prefix, unknowable) — never with `sudo -n true`.
  local nfterr
  if nfterr="$(sudo nft list table inet agent_isolate 2>&1 >/dev/null)"; then
    ok "agent_isolate loaded (persistent skuid drop)"
  elif [[ "${nfterr#"${nfterr%%[![:space:]]*}"}" == sudo:* ]]; then
    warn "agent_isolate: could not verify (${nfterr##*sudo: }) — re-run in a terminal"
  else
    err "agent_isolate NOT loaded — install nft/agent_isolate.nft + nft/agent-isolate.service"
    DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
  fi

  if [[ -f "$PROXY_CA_CERT" ]]; then
    ok "mitmproxy CA present (${PROXY_CA_CERT})"
  else
    warn "no mitmproxy CA at ${PROXY_CA_CERT} — run 'kata up' once to generate it"
  fi

  echo
  echo "base image build (kata build-base):"
  want curl "needed to fetch the Ubuntu cloud image"
  local t iso=""
  for t in cloud-localds xorriso genisoimage mkisofs; do
    if command -v "$t" &>/dev/null; then
      iso="$t"
      break
    fi
  done
  if [[ -n "$iso" ]]; then
    ok "seed ISO packer: ${iso}"
  else
    warn "no seed ISO packer (install cloud-image-utils, or xorriso)"
  fi

  if [[ "$gpu" == true ]]; then
    echo
    echo "GPU passthrough (kata vm --gpu):"
    local groups
    groups="$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)"
    hard "$((groups > 0))" "IOMMU active (${groups} groups)" \
      "no IOMMU groups — enable VT-d/AMD-Vi in firmware"

    # Without interrupt remapping VFIO needs allow_unsafe_interrupts=1, which
    # lets the guest inject MSIs at the host. Never add that flag.
    local ecap ir=0
    for ecap in /sys/class/iommu/*/intel-iommu/ecap; do
      [[ -r "$ecap" ]] || continue
      if (($((0x$(tr -d ' \n' <"$ecap"))) & 8)); then ir=1; fi
    done
    hard "$ir" "interrupt remapping supported (no allow_unsafe_interrupts needed)" \
      "interrupt remapping not detected — refusing to recommend VFIO without it"

    local m missing=()
    for m in vfio vfio_pci vfio_iommu_type1; do
      modinfo "$m" &>/dev/null || missing+=("$m")
    done
    hard "$((${#missing[@]} == 0))" "vfio modules available" \
      "missing kernel modules: ${missing[*]-}"

    # Soft: you can legitimately run doctor while the host owns the card.
    if lspci -Dnk 2>/dev/null | grep -A3 -E '^[0-9a-f:.]+ 03(00|02): 10de:' | grep -q vfio-pci; then
      ok "GPU bound to vfio-pci (sandbox mode)"
    else
      warn "GPU not on vfio-pci — 'kata gpu-mode sandbox' then reboot"
    fi
  fi

  echo
  if ((DOCTOR_FAILS == 0)); then
    ok "all required checks passed"
  else
    err "${DOCTOR_FAILS} required check(s) failed"
  fi
  return "$DOCTOR_FAILS"
}

cmd_doctor "$@"
