# GPU via VFIO

Measured on this laptop, not assumed. The verification steps are the GPU rows in
`tests/MANUAL.md`; this is the reasoning plus the traps.

The end-to-end record is `.claude/scripts/07-gpu-test.sh {pre,post,restore}`:
`--gpu` boots, the card and its audio function appear in the guest,
`kata-install-cuda` installs over the proxy, `nvidia-smi` sees the 4090, torch
runs on it inside the guest, and `--to cuda` bakes a warm base so the next CUDA
session is `--from cuda` rather than a 3G re-download. `restore` also exercises
the guard that refuses `--gpu` while the host still owns the card.

- **Why it needs a reboot to switch sides.** `lsof /dev/dri/card1` shows
  `systemd` (pid 1), `systemd-logind`, `Hyprland`, `Xwayland`, and SDDM's
  `Xorg`. **logind holds a DRM fd on every card on the seat** for seat
  management. Pinning the compositor to the iGPU (`AQ_DRM_DEVICES`) sheds
  Hyprland/Xwayland but not logind or pid 1. So live unbind is impossible; the
  only lever is for `nvidia_drm` never to create the node. That's
  modprobe+initramfs, i.e. a reboot. **Don't re-attempt dynamic unbind.**
- **Why it costs no display.** The panel is on the **Intel iGPU** — only
  `card2-*` connectors are `connected`; the NVIDIA card's `card1-eDP-1`,
  `card1-DP-1`, `card1-HDMI-A-1` are all disconnected (muxless Optimus). The
  dGPU is compute-only. `gpu-mode sandbox` re-checks this and **refuses** if any
  connector on the target card is connected — the MUX is firmware-changeable, so
  verify, don't assume.
- **IOMMU group 16 is clean**: exactly `{01:00.0 GPU, 01:00.1 its HDA}`. No ACS
  override needed. VFIO binds at **group** granularity, so both go to vfio-pci
  and both are passed to the guest. If a group ever contained a bridge/NIC/NVMe,
  passthrough would mean handing those over too — recheck with `gpu-mode status`
  after any firmware update.
- **Interrupt remapping is the security gate, and it passes** (`DMAR-IR:
  Enabled IRQ remapping in x2apic mode`). Without it VFIO needs
  `allow_unsafe_interrupts=1`, which lets the guest inject MSIs at the host —
  that would defeat the whole project. `kata doctor --gpu` treats it as a hard
  failure; **never add the unsafe flag to make things work.**
- **Switching modes RENAMES your display connector.** Hit on the first real
  switch (2026-08-02). With the dGPU present there are two DRM cards, each with
  its own `eDP-1` connector, so aquamarine/Hyprland disambiguates and the Intel
  panel comes out as **`eDP-2`**. Blacklist `nvidia_drm` for VFIO and only one
  card remains — the panel is now **`eDP-1`**. Every config keyed to the old
  name silently stops matching: monitor mode/scale rule (→ compositor falls back
  to its own scale, "everything is zoomed"), `hyprpaper` (→ black background),
  waybar's `output` (→ no bar). The processes keep running, which is why it
  doesn't look like a crash. Fix once, in the compositor config, by matching on
  **`desc:`** (e.g. `desc:BOE NE160QDM-NM4`) instead of the connector name —
  stable in both GPU modes. Not a katastrophe bug, but `gpu-mode` causes it, so
  it's ours to warn about.
- **Drop-ins only, never edit `mkinitcpio.conf`.** `gpu-mode.sh` writes
  `/etc/modprobe.d/kata-vfio.conf` + `/etc/mkinitcpio.conf.d/kata-vfio.conf`. A
  bad drop-in is one `rm` away from fixed (`gpu-mode host` is that rm); a bad
  `mkinitcpio.conf` is a rescue USB. mkinitcpio here is 41, which supports
  `conf.d`.
- **The blacklists are the real lever**, not the `softdep`. Without a bound
  `nvidia_drm` there's no `/dev/dri/cardN` for the dGPU, so logind never grabs
  it. `vfio_pci` also has to be in the initramfs — by the time real root is
  mounted the PCI devices are probed and whoever got there first owns them.
- **vBIOS is dumpable** on this card (150528 bytes, `55aa` magic) — set
  `GPU_ROMFILE` if the guest driver ever refuses to init the device. Many
  Optimus laptops can't do this; we can.
- **Guest driver version is unconstrained by the host's.** With VFIO the host
  has no NVIDIA driver in the path at all. This is the opposite of the old
  CDI/container arrangement, where the container had to match the host exactly
  because it borrowed the host's libs. Install in-guest with `kata build-base
  -- --cuda`, or `sudo kata-install-cuda` in a warm base then re-bake `--to`.
- **`--gpu` needs `RLIMIT_MEMLOCK` raised, and `prealloc=on` does NOT substitute
  for it** (the comment here used to claim it did; wrong, and `--gpu` could
  never have booted). Symptom: `vfio_container_dma_map(…, 0xc0000, 0x18000) =
  -12` → `qemu: hardware error: vfio: DMA mapping failed`, with the CPU dump
  showing `EIP=ffff2618` — SeaBIOS. VFIO pins guest RAM and charges the pages to
  `mm->locked_vm`. The initial map runs as root, where `CAP_IPC_LOCK` skips the
  limit check but the charge still lands; `-run-with user=` then drops to uid
  1001 at the end of `qemu_init`, *after* device realize; then the firmware
  shadows the PAM window at `0xc0000`, which changes a memory region and forces
  a **runtime** remap — now without `CAP_IPC_LOCK`, against the 8M limit
  inherited from your shell, with `locked_vm` already at the full guest size.
  `-ENOMEM`. So an 8G map succeeds and a 96K one aborts the guest. `vm.sh` sets
  `ulimit -l` to guest RAM + 1G before launch (bounded, not `unlimited` — an
  escaped qemu shouldn't be able to pin arbitrary host memory); the limit is
  inherited across the uid drop. `prealloc=on` stays, but only to pay the
  fault-in cost at boot rather than as stalls mid-run.
- **"Image builds need the egress gate DOWN" is retired.** That was a
  GPU-container rule (`pacman`/`npm` as uid 1001 vs the proxy-only gate).
  `build-base.sh` boots the cloud image on plain SLIRP as *you*, and the gate
  only scopes uid 1001, so it is simply irrelevant now.

## `-vga none` made the GPU the primary display, and SeaBIOS wedged on its ROM

Found 2026-09-15, the first `--gpu` boot after `qemu-device-surface` landed.

**Symptom:** `kata vm --gpu` hangs at "waiting for ssh" forever. qemu is alive,
one vCPU pegged at ~100%, RSS shows prealloc finished — and **`serial.log` is
zero bytes**.

**Cause:** removing the emulated stdvga left the passed-through 4090 as the only
VGA-class device on the bus. SeaBIOS therefore promoted it to primary display and
tried to *execute* its option ROM to bring up a console. On a laptop dGPU that
ROM is routinely incomplete — the real VBIOS lives in the system firmware, which
POSTed the card long before qemu saw it — so SeaBIOS never returned. Before
`-vga none` this could not happen: stdvga was primary, and the card's ROM was
exposed but never run.

**Fix:** `romfile=` (empty) on the vfio-pci devices, which is the same trick
`virtio-net-pci` has always used. The guest's nvidia driver reads the VBIOS off
the card itself on Linux, so nothing is lost.

**The diagnostic worth keeping, because it generalises:** *an empty `serial.log`
next to a live qemu is a **firmware-stage** hang, not a slow boot.* SeaBIOS
writes to the VGA console and to debugcon — never to `ttyS0`. Nothing reaches the
serial log until the Linux kernel starts with `console=ttyS0`. So "no output at
all" and "output that stops partway" are completely different failures, and only
the second one is about the guest OS.

**Latent bug found in passing:** `GPU_ROMFILE` was appended to `VFIO_ARGS[-1]`,
i.e. the last device in the IOMMU group — the **HDMI audio function**, not the
GPU. It had never been caught because the variable has never been set; it would
have presented as "I dumped the vBIOS and passing it changed nothing". Now
matched against `$GPU_ADDR` inside the loop.

## Benign qemu warning with `--gpu` — don't re-debug it

`vfio_container_dma_map(…, 0xe0000000000, 0x400000000, …) = -22 (Invalid
argument)` followed by `PCI peer-to-peer transactions on BARs are not
supported`. That is qemu asking the kernel to IOMMU-map the GPU's own 16G BAR so
*other passed-through devices* could DMA into it; vfio type1 can't pin MMIO
without p2pdma, so it declines. Nothing in a single-GPU setup uses that mapping
— the CPU reaches the BAR through EPT and the driver's DMA targets RAM. It says
`warning:`, not `hardware error:`, and the guest boots. It would only matter
with two GPUs doing direct peer-to-peer (NCCL P2P).
