#!/usr/bin/env bash
# build-base.sh — build the blank guest base (Ubuntu 24.04 + cloud-init):
#   1. fetch the cloud image (cached, sha-checked)
#   2. render guest/cloud-init/user-data
#   3. pack a NoCloud seed ISO
#   4. boot it once; cloud-init provisions and powers off
#   5. install it as base '$VM_BASE_NAME'
#
# The build boot uses SLIRP, not the bridge: it needs plain NAT (apt, installers)
# and must not depend on `kata up`. user-data switches the guest to the bridge +
# proxy at the end, so the artifact is sandbox-shaped.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

# As you: a root run leaves root-owned guest/.cache + guest/build behind, which
# breaks the next build.
[[ $EUID -ne 0 ]] || {
  echo "run as yourself, not root — 'kata build-base'" >&2
  exit 1
}

GUEST_DIR="${REPO_ROOT}/guest"
CACHE_DIR="${GUEST_DIR}/.cache"
BUILD_DIR="${GUEST_DIR}/build"
WITH_CUDA=false
BOOT_TIMEOUT="${BOOT_TIMEOUT:-2400}" # 40 min; CUDA pulls ~3 GB

usage() {
  cat <<EOF
usage: kata build-base [--cuda]

Build the blank guest base at:
  $(base_img "$VM_BASE_NAME")

  --cuda   also install the NVIDIA driver + CUDA toolkit in the image
           (~3 GB, much slower). The usual path is a warm base instead:
             kata vm --ssh --gpu --to cuda    # then: sudo kata-install-cuda
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
  --cuda)
    WITH_CUDA=true
    shift
    ;;
  -h | --help) usage ;;
  *)
    echo "unknown arg: $1"
    usage
    ;;
  esac
done

# --- Preflight ------------------------------------------------------------
for b in qemu-system-x86_64 qemu-img curl python3; do
  command -v "$b" >/dev/null || {
    echo "missing dependency: $b"
    exit 1
  }
done

# NoCloud keys off the volume label CIDATA, not the filename.
ISO_TOOL=""
for c in cloud-localds xorriso genisoimage mkisofs; do
  command -v "$c" >/dev/null && {
    ISO_TOOL="$c"
    break
  }
done
[[ -n "$ISO_TOOL" ]] || {
  echo "need one of: cloud-localds (cloud-image-utils), xorriso, genisoimage, mkisofs"
  exit 1
}

[[ -r /dev/kvm ]] || {
  echo "/dev/kvm not readable — the build boot needs KVM (add yourself to the kvm group)"
  exit 1
}

[[ -r "$PROXY_CA_CERT" ]] || refuse "mitmproxy CA not found at ${PROXY_CA_CERT}" <<EOF
the CA is baked into the base; without it every HTTPS call in the sandbox fails
cert validation, and you find out 10-40 minutes from now.
fix: kata up
EOF

# Check the destination now, not after the build.
echo "[*] bases → ${VM_BASES_DIR}"
require_storage "$VM_BASES_DIR"

mkdir -p "$CACHE_DIR" "$BUILD_DIR"

# --- 1. Cloud image -------------------------------------------------------
# `.../release` is a symlink Ubuntu re-points every few weeks, so a cached image
# can stop matching fresh sums without any tampering. Hence: a mismatch on a
# CACHED file refetches once; a mismatch on a FRESH download is fatal.
IMG_CACHE="${CACHE_DIR}/${UBUNTU_IMAGE_NAME}"

fetch_image() {
  echo "[1/5] downloading ${UBUNTU_IMAGE_NAME}"
  curl -fL --progress-bar -o "${IMG_CACHE}.part" "${UBUNTU_IMAGE_URL}"
  mv -f "${IMG_CACHE}.part" "$IMG_CACHE"
}

# Re-read per attempt: the sums must belong to the image just pulled.
expected_sha() {
  if [[ -n "${UBUNTU_IMAGE_SHA256:-}" ]]; then
    echo "$UBUNTU_IMAGE_SHA256"
    return 0
  fi
  local pub
  pub="$(curl -fsSL "${UBUNTU_IMAGE_SUMS}" | awk -v f="*${UBUNTU_IMAGE_NAME}" '$2==f {print $1}')"
  [[ -n "$pub" ]] || {
    echo "[!] could not find ${UBUNTU_IMAGE_NAME} in ${UBUNTU_IMAGE_SUMS}" >&2
    exit 1
  }
  echo "$pub"
}

if [[ -s "$IMG_CACHE" ]]; then
  echo "[1/5] using cached ${IMG_CACHE}"
else
  fetch_image
  FRESH=1
fi

WANT="$(expected_sha)"
ACTUAL_SHA="$(sha256sum "$IMG_CACHE" | cut -d' ' -f1)"

if [[ "$ACTUAL_SHA" != "$WANT" && -z "${FRESH:-}" ]]; then
  echo "[=] cached image ≠ the published digest (${UBUNTU_RELEASE} was probably respun) — re-downloading once, then verifying again"
  rm -f "$IMG_CACHE"
  fetch_image
  FRESH=1
  WANT="$(expected_sha)"
  ACTUAL_SHA="$(sha256sum "$IMG_CACHE" | cut -d' ' -f1)"
fi

if [[ "$ACTUAL_SHA" != "$WANT" ]]; then
  rm -f "$IMG_CACHE"
  if [[ -n "${UBUNTU_IMAGE_SHA256:-}" ]]; then
    refuse "sha256 mismatch on a freshly downloaded image" <<EOF
expected: $WANT
actual:   $ACTUAL_SHA

UBUNTU_IMAGE_SHA256 is pinned. If Ubuntu respun the release, the pinned image
is gone from the 'release' symlink; otherwise this is a real integrity failure.
fix: UBUNTU_IMAGE_BASE=https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release-YYYYMMDD   (in config.local.sh)
EOF
  else
    refuse "sha256 mismatch on a freshly downloaded image" <<EOF
expected: $WANT
actual:   $ACTUAL_SHA

The image and the sums come from the same directory, so this should not happen.
Treat it as a real integrity failure.
fix: none — do not proceed; investigate
EOF
  fi
fi

if [[ -n "${UBUNTU_IMAGE_SHA256:-}" ]]; then
  echo "      sha256 pinned + verified"
else
  echo "      sha256 matches published SHA256SUMS (TOFU — not a pin) — to pin it, add UBUNTU_IMAGE_SHA256=$ACTUAL_SHA to config.local.sh"
fi

# --- 2. Render user-data --------------------------------------------------
echo "[2/5] rendering cloud-init user-data"
SEED_DIR="${BUILD_DIR}/seed"
rm -rf "$SEED_DIR"
mkdir -p "$SEED_DIR"
cp "${GUEST_DIR}/cloud-init/meta-data" "${SEED_DIR}/meta-data"

# /bin/true, not `true`: in a YAML list a bare `true` is a boolean and fails
# cloud-init's schema check on every build.
CUDA_CMD='[/bin/true]'
[[ "$WITH_CUDA" == true ]] && CUDA_CMD='[/usr/local/sbin/kata-install-cuda]'

# Python, not sed: base64 blobs and a re-indented PEM make sed replacements a
# footgun. The heredoc is UNQUOTED, so bash expands it — no backticks or $(...)
# in the Python comments.
python3 - "$@" <<PY
import base64, pathlib, sys

guest = pathlib.Path("${GUEST_DIR}")
tpl   = (guest / "cloud-init" / "user-data").read_text()

def b64(p):
    return base64.b64encode(pathlib.Path(p).read_bytes()).decode()

# The CA sits under a YAML block scalar: continuation lines need its 6-space indent.
ca_lines = pathlib.Path("${PROXY_CA_CERT}").read_text().strip().splitlines()
ca = ("\n" + " " * 6).join(ca_lines)

tokens = {
    "@@AGENT_UID@@":     "${AGENT_UID}",
    "@@HOST_IP@@":       "${HOST_IP}",
    "@@VM_IP@@":         "${VM_IP}",
    "@@PREFIX@@":        "${PREFIX}",
    "@@PROXY_PORT@@":    "${PROXY_PORT}",
    "@@SEARXNG_PORT@@":  "${SEARXNG_PORT}",
    "@@KEY_SENTINEL@@":  "${KEY_SENTINEL}",
    "@@FASTFETCH_VER@@": "${FASTFETCH_VER}",
    "@@CUDA_CMD@@":      "${CUDA_CMD}",
    "@@MITM_CA@@":       ca,
    # System-wide files only; per-user dotfiles go through 'kata home seed'.
    "@@B64_STARSHIP@@":  b64(guest / "configs" / "starship.toml"),
    "@@B64_CUDA@@":      b64(guest / "cuda-install.sh"),
    "@@B64_TOOLS@@":     b64(guest / "tools-install.sh"),
}
for k, v in tokens.items():
    tpl = tpl.replace(k, v)

# A half-substituted user-data boots into a subtly wrong guest. Comments exempt.
leftover = [l for l in tpl.splitlines()
            if "@@" in l and not l.lstrip().startswith("#")]
if leftover:
    sys.exit("unsubstituted tokens remain:\n  " + "\n  ".join(leftover))

pathlib.Path("${SEED_DIR}/user-data").write_text(tpl)
print("      user-data rendered ({} bytes)".format(len(tpl)))
PY

# --- 3. Seed ISO ----------------------------------------------------------
echo "[3/5] packing NoCloud seed ISO"
SEED_ISO="${BUILD_DIR}/seed.iso"
rm -f "$SEED_ISO"
case "$ISO_TOOL" in
cloud-localds)
  cloud-localds "$SEED_ISO" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
  ;;
xorriso)
  xorriso -as mkisofs -output "$SEED_ISO" -volid CIDATA -joliet -rock \
    "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" >/dev/null 2>&1
  ;;
*)
  "$ISO_TOOL" -output "$SEED_ISO" -volid CIDATA -joliet -rock \
    "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data" >/dev/null 2>&1
  ;;
esac
[[ -s "$SEED_ISO" ]] || {
  echo "seed ISO not produced"
  exit 1
}

# --- 4. Provisioning boot -------------------------------------------------
# Grow first: growpart only runs in this boot (the only one with cloud-init), and
# session overlays are created at the same size.
WIP="${BUILD_DIR}/base.qcow2"
rm -f "$WIP"
qemu-img convert -O qcow2 "$IMG_CACHE" "$WIP"
qemu-img resize "$WIP" "$VM_DISK_SIZE" >/dev/null

SERIAL_LOG="${BUILD_DIR}/build-serial.log"
rm -f "$SERIAL_LOG"
echo "[4/5] provisioning boot (cloud-init), a few minutes${WITH_CUDA:+ and a lot longer with CUDA} — serial log: ${SERIAL_LOG}"

set +e
# Same stripped surface as a session (threat: qemu-device-surface). The one
# difference: `-netdev user` is SLIRP, the library behind an escape in
# knowledge/vm-escape-2026-08.md. Accepted here only because this runs
# unprivileged (a bridge tap needs root), with no agent, on Ubuntu's own image
# (threat: no-slirp is scoped to sessions). A privileged variant should use the
# bridge.
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
  -nodefaults \
  -machine "q35,accel=kvm,${QEMU_MACHINE_OPTS}" \
  -vga none \
  -cpu host \
  -m 4G -smp 4 \
  -drive "file=${WIP},if=virtio,format=qcow2" \
  -drive "file=${SEED_ISO},if=virtio,format=raw,readonly=on" \
  -netdev user,id=n0 \
  -device virtio-net-pci,netdev=n0,romfile= \
  -display none -monitor none \
  -serial "file:${SERIAL_LOG}" </dev/null
QRC=$?
set -e

if [[ $QRC -eq 124 ]]; then
  echo "[!] build boot hit the ${BOOT_TIMEOUT}s timeout — see ${SERIAL_LOG}"
  exit 1
elif [[ $QRC -ne 0 ]]; then
  echo "[!] qemu exited ${QRC} — see ${SERIAL_LOG}"
  exit 1
fi

# The last runcmd echoes this to /dev/console. Not power_state.message: that goes
# through wall, which reaches no terminal on a headless boot.
grep -q 'katastrophe base provisioned' "$SERIAL_LOG" || {
  echo "[!] cloud-init did not report completion — base NOT installed."
  echo "    last 40 lines of ${SERIAL_LOG}:"
  tail -40 "$SERIAL_LOG"
  exit 1
}
# Two lines are benign on every build (`cloud-init clean` removes state later
# steps expect); filtered so the real errors stay readable.
if grep -iE 'cloud-init.*(fail|error|traceback)' "$SERIAL_LOG" |
  grep -qvE 'boot finished file|Failed at stage.*modules-final'; then
  echo "[!] cloud-init reported errors during provisioning:"
  grep -inE 'cloud-init.*(fail|error|traceback)' "$SERIAL_LOG" |
    grep -vE 'boot finished file|Failed at stage.*modules-final' | tail -20
  echo "    review ${SERIAL_LOG}; the base was still installed."
fi
if grep -q 'failed schema validation' "$SERIAL_LOG"; then
  echo "[!] cloud-config failed schema validation. Detail from the guest:"
  sed -n '/cloud-init schema/,/^$/p' "$SERIAL_LOG" | tail -20
fi

# --- 5. Install -----------------------------------------------------------
# Same namespace `--from` and `kata bases` read. No sudo: the bases dir is yours
# (and out of the agent's reach, threat: base-poisoning).
echo "[5/5] installing base"
require_storage "$VM_BASES_DIR"
mkdir -p "$VM_BASES_DIR"
DEST="$(base_img "$VM_BASE_NAME")"
install -m 0644 "$WIP" "$DEST"
rm -f "$WIP"
base_meta_write "$VM_BASE_NAME" build "" false
qemu-img info "$DEST" | head -5

cat <<EOF

[ok] base installed: $(base_describe "$VM_BASE_NAME")
     ${DEST}

Warm bases baked from an older version of this one are now stale — 'kata bases'
marks them. Re-bake them off the new one (e.g. --from base --to cuda).

next:
  kata up                  # bridge + nft + proxy
  kata vm --ssh            # CPU session, detached + ssh
  kata vm --ssh --gpu      # with the GPU (needs: kata gpu-mode sandbox)
EOF
