#!/usr/bin/env bash
# gpu-mode.sh — decide which side owns the dGPU across a reboot.
#
#   gpu-mode.sh status    what the host is set to, and what it's actually doing
#   gpu-mode.sh host      the host keeps the GPU (nvidia driver) — the default
#   gpu-mode.sh sandbox   the GPU is reserved for VFIO, so `kata vm --gpu` works
#   gpu-mode.sh vbios     fingerprint the card's option ROM, or compare to the
#                         recorded one (threat: gpu-firmware-persistence)
#
# ---------------------------------------------------------------------------
# Why this needs a reboot, and why that is not laziness
# ---------------------------------------------------------------------------
# The obvious design is to unbind the card from `nvidia` at session start and
# rebind afterwards, no reboot. That does not work here, and it is worth writing
# down why so nobody re-attempts it:
#
#   $ lsof /dev/dri/card1
#   systemd (pid 1), systemd-logind, Hyprland, Xwayland
#
# systemd-logind holds a DRM fd on every card on the seat, for seat management —
# it grabs the node as soon as it exists, and it is not going to let go for us.
# Pinning the compositor to the iGPU (AQ_DRM_DEVICES) would drop Hyprland and
# Xwayland, but not logind or pid 1. The only way to free the device is for the
# DRM node never to be created, i.e. for `nvidia_drm` not to bind it at boot.
# That is a modprobe/initramfs decision, so it is a reboot.
#
# The saving grace is that this machine's panel is on the Intel iGPU (the
# NVIDIA connectors are all disconnected — muxless Optimus), so reserving the
# dGPU for VFIO costs you no display, only host CUDA.
#
# ---------------------------------------------------------------------------
# What it writes
# ---------------------------------------------------------------------------
#   $VFIO_MODPROBE_CONF     vfio-pci claims the IDs; nvidia* blacklisted
#   $VFIO_MKINITCPIO_CONF   vfio-pci into the initramfs, so it wins the race
#
# Both are DROP-IN files, and this script never edits mkinitcpio.conf itself.
# A botched in-place edit of that file is an unbootable machine; a drop-in that
# goes wrong is one `rm` away from fixed (and `gpu-mode.sh host` is that rm).
#
# It does NOT touch the kernel command line, because it does not need to: the
# IOMMU is already active on this host (Intel VT-d defaults on with a sane DMAR
# table) and interrupt remapping is enabled, which is what VFIO actually
# requires. Nothing here needs a bootloader edit.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

ACTION="${1:-status}"

usage() {
  # The action list is lines 4..N of this file, terminated by the blank comment
  # line. Matched rather than hardcoded as '3,6p': that range silently truncated
  # the help the first time an action was added below it.
  sed -n '4,/^#$/p' "$0" | sed 's/^# \?//;/^$/d'
  exit 1
}

# --- Resolve the device + its IOMMU group ---------------------------------
ADDR="$(gpu_addr)"
[[ -n "$ADDR" ]] || {
  echo "no NVIDIA GPU found (set GPU_PCI_ADDR in config.local.sh to override)"
  exit 1
}
mapfile -t GROUP < <(gpu_group_devices "$ADDR") || {
  echo "could not read the IOMMU group for $ADDR — is the IOMMU enabled?"
  exit 1
}
# vfio-pci claims devices by vendor:device id, not by address.
IDS=""
for d in "${GROUP[@]}"; do
  id="$(lspci -Dn -s "$d" 2>/dev/null | awk '{print $3}')"
  [[ -n "$id" ]] && IDS="${IDS:+${IDS},}${id}"
done
[[ -n "$IDS" ]] || {
  echo "could not resolve PCI ids for group: ${GROUP[*]}"
  exit 1
}

initramfs_rebuild() {
  if command -v mkinitcpio >/dev/null; then
    echo "[*] regenerating initramfs (mkinitcpio -P)"
    mkinitcpio -P
  elif command -v dracut >/dev/null; then
    echo "[*] regenerating initramfs (dracut --regenerate-all)"
    dracut --force --regenerate-all
  elif command -v update-initramfs >/dev/null; then
    echo "[*] regenerating initramfs (update-initramfs -u -k all)"
    update-initramfs -u -k all
  else
    echo "[!] no known initramfs tool found — regenerate it yourself before rebooting, or vfio-pci will not load early enough to claim the card"
    return 1
  fi
}

cmd_status() {
  echo "GPU:        $ADDR"
  echo "IOMMU grp:  ${GROUP[*]}"
  echo "PCI ids:    $IDS"
  echo
  echo "configured mode:  $([[ -f "$VFIO_MODPROBE_CONF" ]] && echo sandbox || echo host)"
  echo "  $VFIO_MODPROBE_CONF   $([[ -f "$VFIO_MODPROBE_CONF" ]] && echo present || echo absent)"
  echo "  $VFIO_MKINITCPIO_CONF $([[ -f "$VFIO_MKINITCPIO_CONF" ]] && echo present || echo absent)"
  echo
  echo "live bindings (this is what actually matters right now):"
  local all_vfio=1
  for d in "${GROUP[@]}"; do
    local drv
    drv="$(pci_driver "$d")"
    printf '  %-14s -> %s\n' "$d" "${drv:-<none>}"
    [[ "$drv" == "vfio-pci" ]] || all_vfio=0
  done
  echo
  if [[ $all_vfio -eq 1 ]]; then
    echo "=> ready: 'kata vm --gpu' will work."
  elif [[ -f "$VFIO_MODPROBE_CONF" ]]; then
    echo "=> configured for sandbox but NOT yet in effect — reboot to apply."
  else
    echo "=> host owns the GPU. 'kata vm --gpu' will refuse."
    echo "   To hand it to the sandbox: sudo $0 sandbox && sudo reboot"
  fi
}

cmd_sandbox() {
  [[ $EUID -eq 0 ]] || {
    echo "run as root (sudo $0 sandbox)"
    exit 1
  }

  # Refuse if the dGPU is currently driving a connected display. On this laptop
  # it is not (muxless Optimus; the panel is on i915), but that is a property of
  # the machine's MUX setting, which is changeable in firmware — so check rather
  # than assume. Taking the GPU away from a live display leaves a black screen.
  local sysfs_dev="/sys/bus/pci/devices/${ADDR}/drm"
  if [[ -d "$sysfs_dev" ]]; then
    local card conn
    for card in "$sysfs_dev"/card*; do
      [[ -e "$card" ]] || continue
      for conn in "$card"/card*-*/status; do
        [[ -r "$conn" ]] || continue
        if [[ "$(cat "$conn")" == "connected" ]]; then
          echo "[!] REFUSING: ${conn%/status} is connected — this GPU is driving a display."
          echo "    Handing it to VFIO would black out that output. Switch the laptop's"
          echo "    MUX/graphics mode to hybrid (iGPU drives the panel) first."
          exit 1
        fi
      done
    done
  fi

  echo "[*] reserving ${GROUP[*]} (ids: $IDS) for vfio-pci"

  cat >"$VFIO_MODPROBE_CONF" <<EOF
# Written by katastrophe scripts/gpu-mode.sh — do not edit by hand.
# Reserves the dGPU for VFIO so it can be passed into the sandbox VM.
# Remove this file (or run 'gpu-mode.sh host') to give the GPU back to the host.

# vfio-pci claims these devices before anything else can.
options vfio-pci ids=${IDS}

# Load vfio-pci ahead of the nvidia modules. On its own this is not enough
# (nvidia can still be pulled in by something else first), which is why the
# blacklists below are also here.
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep nvidia_modeset pre: vfio-pci

# The real lever. Without a bound nvidia_drm there is no /dev/dri/cardN for the
# dGPU, so systemd-logind never grabs it and the device stays free for VFIO.
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF
  chmod 0644 "$VFIO_MODPROBE_CONF"
  echo "[+] wrote $VFIO_MODPROBE_CONF"

  # vfio-pci must be in the initramfs: by the time the real root is mounted the
  # PCI devices have already been probed, and whichever driver got there first
  # owns them.
  mkdir -p "$(dirname "$VFIO_MKINITCPIO_CONF")"
  cat >"$VFIO_MKINITCPIO_CONF" <<'EOF'
# Written by katastrophe scripts/gpu-mode.sh — do not edit by hand.
# A drop-in, never an edit to mkinitcpio.conf: a broken drop-in is one rm away
# from fixed, a broken mkinitcpio.conf is a rescue USB.
MODULES+=(vfio_pci vfio_iommu_type1 vfio)
EOF
  chmod 0644 "$VFIO_MKINITCPIO_CONF"
  echo "[+] wrote $VFIO_MKINITCPIO_CONF"

  initramfs_rebuild || true

  cat <<EOF

[ok] configured for SANDBOX. Reboot to apply:

    sudo reboot

After the reboot:
    kata gpu-mode status                     # every device should say vfio-pci
    kata up
    kata vm --workspace DIR --gpu

While in this mode the HOST has no CUDA — nvidia-smi will report no devices,
and anything on the host that wants the GPU will fail. Your display is
unaffected (it is on the iGPU). To take it back:  sudo $0 host && sudo reboot
EOF
}

cmd_host() {
  [[ $EUID -eq 0 ]] || {
    echo "run as root (sudo $0 host)"
    exit 1
  }
  local changed=0
  for f in "$VFIO_MODPROBE_CONF" "$VFIO_MKINITCPIO_CONF"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      echo "[-] removed $f"
      changed=1
    fi
  done
  if [[ $changed -eq 0 ]]; then
    echo "[=] already configured for host (no drop-ins present)"
  else
    initramfs_rebuild || true
  fi
  cat <<EOF

[ok] configured for HOST. Reboot to apply:

    sudo reboot

After the reboot the nvidia driver takes the card back and host CUDA works
again. 'kata vm --gpu' will refuse until you switch back to sandbox mode.
EOF
}

# --- vbios: is the card's firmware still the one we started with? ----------
# threat: gpu-firmware-persistence. Under --gpu the guest drives the real card,
# so the open question is whether it can write the card's FLASH — which would
# survive `gpu-mode host` and the reboot, after which the HOST driver binds a
# card an untrusted guest modified. The PCI reset at reboot clears device state;
# it does not clear flash.
#
# This does NOT answer that question — answering it means establishing whether
# signature enforcement covers every writable region the guest can reach, and
# that is research, not a script. What it does is the operationally useful half:
# record a fingerprint now, compare it later. "Can it?" stays open; "did it?"
# becomes answerable, which is the difference between an accepted risk and an
# unmonitored one.
#
# Caveats, stated because a firmware check that over-claims is worse than none:
#   - This reads the PCI ROM BAR (the option ROM the card exposes). That is not
#     the whole of the card's writable firmware — GSP images and any region the
#     driver flashes by MMIO are NOT covered. A match here is not a clean bill.
#   - The ROM BAR is only readable while nothing else is driving the card, so
#     this refuses while a session is up.
VBIOS_HASH_FILE="${VBIOS_HASH_FILE:-${VM_IMAGES_DIR}/gpu-vbios.sha256}"

cmd_vbios() {
  [[ $EUID -eq 0 ]] || {
    echo "vbios: needs root to read the ROM BAR — run 'kata gpu-mode vbios'"
    exit 1
  }
  if [[ -e "$VM_STATE_FILE" ]]; then
    echo "vbios: a VM session is running — stop it first (kata vm --stop)."
    echo "  The ROM BAR cannot be read while the guest is driving the card,"
    echo "  and poking at it mid-session is not a thing to do to a live GPU."
    exit 1
  fi

  local rom="/sys/bus/pci/devices/${ADDR}/rom" cur
  [[ -e "$rom" ]] || {
    echo "vbios: no ROM BAR exposed at ${rom} — cannot fingerprint this card."
    exit 1
  }
  # `|| cur=""` is load-bearing, and its absence is why the first version of
  # this printed NOTHING and exited non-zero. This script runs under
  # `set -euo pipefail`; the ROM BAR returns EIO while the card is on vfio-pci,
  # so `dd` fails, `pipefail` fails the whole pipeline, and under `set -e` a
  # failed command substitution in an assignment kills the script right there —
  # before any of the diagnostics below get a chance to explain themselves.
  # Same family as the bare `[[ … ]] &&` trap documented at the top of lib.sh:
  # under `set -e`, the silent death is always the failure mode.
  echo 1 >"$rom" 2>/dev/null || true
  cur="$(dd if="$rom" bs=64k 2>/dev/null | sha256sum | awk '{print $1}')" || cur=""
  echo 0 >"$rom" 2>/dev/null || true

  # An unreadable ROM hashes as the empty stream. Reporting that as a stable
  # fingerprint would be the over-claiming check this repo keeps warning about:
  # it would match itself forever and prove nothing.
  local empty
  empty="$(printf '' | sha256sum | awk '{print $1}')"
  if [[ -z "$cur" || "$cur" == "$empty" ]]; then
    echo "vbios: the ROM BAR read back empty — no fingerprint taken."
    echo "  Common when the card is bound to vfio-pci. Try again in host mode:"
    echo "      kata gpu-mode host && sudo reboot"
    exit 1
  fi

  if [[ ! -f "$VBIOS_HASH_FILE" ]]; then
    install -m 0644 -D /dev/null "$VBIOS_HASH_FILE"
    printf '%s  %s  recorded %s\n' "$cur" "$ADDR" "$(date -Is)" >"$VBIOS_HASH_FILE"
    echo "vbios: baseline recorded for ${ADDR}"
    echo "  ${cur}"
    echo "  ${VBIOS_HASH_FILE}"
    echo
    echo "  Re-run after GPU sessions to compare. Note what this does NOT cover:"
    echo "  the ROM BAR only, not GSP or anything flashed over MMIO."
    return 0
  fi

  local want
  want="$(awk '{print $1}' "$VBIOS_HASH_FILE")"
  if [[ "$cur" == "$want" ]]; then
    echo "vbios: unchanged since $(awk '{print $4}' "$VBIOS_HASH_FILE")"
    echo "  ${cur}"
  else
    cat <<EOF
vbios: *** THE CARD'S OPTION ROM HAS CHANGED ***
  recorded  ${want}
  now       ${cur}
  device    ${ADDR}
  baseline  ${VBIOS_HASH_FILE}

  A vBIOS update or a firmware tool you ran yourself explains this. So does
  threat: gpu-firmware-persistence. Do not hand this card back to the host
  (kata gpu-mode host) until you know which.
  To accept the new image as the baseline: rm ${VBIOS_HASH_FILE} and re-run.
EOF
    exit 2
  fi
}

case "$ACTION" in
status) cmd_status ;;
sandbox) cmd_sandbox ;;
host) cmd_host ;;
vbios) cmd_vbios ;;
-h | --help) usage ;;
*)
  echo "unknown action: $ACTION"
  usage
  ;;
esac
