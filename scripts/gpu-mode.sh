#!/usr/bin/env bash
# gpu-mode.sh — decide which side owns the dGPU across a reboot.
#
#   kata gpu-mode status    what the host is set to, and what it is doing
#   kata gpu-mode host      the host keeps the GPU (nvidia driver) — the default
#   kata gpu-mode sandbox   the GPU is reserved for VFIO, so `kata vm --gpu` works
#   kata gpu-mode vbios     fingerprint the card's option ROM, or compare to the
#                           recorded one (threat: gpu-firmware-persistence)
#
#
# A reboot, not a live unbind: systemd-logind holds a DRM fd on every card on the
# seat and will not let go, so the only way to free the dGPU is for its DRM node
# never to exist — a modprobe/initramfs decision. The panel is on the iGPU
# (muxless Optimus), so sandbox mode costs host CUDA, not the display.
#
# Writes two drop-ins, never edits mkinitcpio.conf ($VFIO_MODPROBE_CONF,
# $VFIO_MKINITCPIO_CONF); `host` is the rm. No kernel cmdline change: VT-d and
# interrupt remapping are already on here.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

ACTION="${1:-status}"

usage() {
  # The action list in the header, up to the first bare `#` line.
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
    echo "   To hand it to the sandbox: kata gpu-mode sandbox && sudo reboot"
  fi
}

cmd_sandbox() {
  [[ $EUID -eq 0 ]] || {
    echo "run as root (kata gpu-mode sandbox)"
    exit 1
  }

  # The MUX is a firmware setting, so check rather than assume: taking the GPU
  # from a connected display blacks it out.
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

  # In the initramfs, or another driver probes the card first and owns it.
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
    kata vm --ssh --gpu

While in this mode the HOST has no CUDA — nvidia-smi will report no devices,
and anything on the host that wants the GPU will fail. Your display is
unaffected (it is on the iGPU). To take it back:  kata gpu-mode host && sudo reboot
EOF
}

cmd_host() {
  [[ $EUID -eq 0 ]] || {
    echo "run as root (kata gpu-mode host)"
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
# threat: gpu-firmware-persistence. The guest drives the real card; if it can
# write the card's flash, that survives the reboot back to host mode. This does
# not answer "can it?" — it makes "did it?" answerable: record, then compare.
#
# Does not over-claim: this is the PCI ROM BAR only, not GSP or anything flashed
# over MMIO, so a match is not a clean bill. Unreadable while a session runs.
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
  # `|| cur=""`: on vfio-pci the ROM BAR returns EIO, and under set -e +
  # pipefail the failed substitution would kill the script before it explains.
  echo 1 >"$rom" 2>/dev/null || true
  cur="$(dd if="$rom" bs=64k 2>/dev/null | sha256sum | awk '{print $1}')" || cur=""
  echo 0 >"$rom" 2>/dev/null || true

  # An unreadable ROM hashes as the empty stream, which would match forever.
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
