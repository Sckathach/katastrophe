#!/usr/bin/env bash
# build-base.sh — build the blank guest base qcow2 (Ubuntu 24.04 + cloud-init).
#
# Replaces the old Nix flake build. Shape:
#   1. fetch the Ubuntu cloud image (cached, integrity-checked)
#   2. render guest/cloud-init/user-data (token substitution + base64 embeds)
#   3. pack a NoCloud seed ISO
#   4. boot it once on plain SLIRP NAT; cloud-init provisions and powers off
#   5. install the result at $VM_BASE
#
# The build boot deliberately uses SLIRP, NOT the sandbox bridge: it needs
# ordinary NAT egress (apt, nodesource, starship.rs, astral.sh, the fastfetch
# release) and must not depend on `kata up`, a live mitmproxy, or the allowlist.
# user-data switches the guest over to the bridge + proxy at the very end, so
# the artifact is sandbox-shaped even though the build was not.
#
# Consequence: this replaces the old "builds need the egress gate DOWN" gotcha.
# The gate is uid-1001-scoped and this runs as you, so it is simply irrelevant.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

# As YOU, not root: the image cache, the render tree and the seed ISO must end
# up owned by you (only the final install into $VM_BASES_DIR self-sudos), and
# the provisioning boot is an ordinary user qemu on SLIRP. Running the whole
# thing as root leaves a root-owned guest/.cache + guest/build behind, which
# then breaks the next non-root build.
[[ $EUID -ne 0 ]] || {
  echo "run as yourself, not root — 'kata build-base' self-sudos the one step that needs it" >&2
  exit 1
}

GUEST_DIR="${REPO_ROOT}/guest"
CACHE_DIR="${GUEST_DIR}/.cache"
BUILD_DIR="${GUEST_DIR}/build"
WITH_CUDA=false
BOOT_TIMEOUT="${BOOT_TIMEOUT:-2400}" # 40 min; CUDA pulls ~3 GB

usage() {
  cat <<EOF
usage: $0 [--cuda]

Build the blank guest base at:
  $(base_img "$VM_BASE_NAME")

  --cuda   also install the NVIDIA driver + CUDA toolkit in the image
           (~3 GB, much slower). Off by default — the usual path is to bake
           CUDA into a named warm base instead:
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

# Seed ISO packer. cloud-localds (cloud-image-utils) is the purpose-built one;
# xorriso/genisoimage do the same job with an explicit volume label. NoCloud
# keys off the label CIDATA, not the filename.
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

# The guest must trust the per-deployment mitmproxy CA or every HTTPS call
# inside the sandbox fails cert validation. net-up.sh generates it.
[[ -r "$PROXY_CA_CERT" ]] || refuse "mitmproxy CA not found at ${PROXY_CA_CERT}" <<EOF
the CA is baked into the base; without it every HTTPS call in the sandbox fails
cert validation, and you find out 10-40 minutes from now.
fix: kata up
EOF

# Check the destination NOW, not after a 10-40 minute build.
echo "[*] bases → ${VM_BASES_DIR}"
require_storage "$VM_BASES_DIR"

mkdir -p "$CACHE_DIR" "$BUILD_DIR"

# --- 1. Cloud image -------------------------------------------------------
# Integrity: Ubuntu publishes SHA256SUMS next to the image. If
# UBUNTU_IMAGE_SHA256 is set (config.local.sh) we hard-pin against it. If not,
# we verify against the published SHA256SUMS and PRINT the digest so you can
# pin it — that is trust-on-first-use, not a pin, and it is labelled as such.
#
# The subtlety that bit us: $UBUNTU_IMAGE_BASE ends in `.../noble/release`,
# which is a SYMLINK to the latest respin (release-20260731 or whatever).
# Ubuntu republishes it every few weeks, and the image AND its SHA256SUMS both
# change. So a perfectly good cached image starts failing verification against
# freshly-fetched sums — which looks exactly like tampering and is not.
#
# Hence: a mismatch on a CACHED file is recoverable (the upstream moved), a
# mismatch on a FRESHLY DOWNLOADED file is not (that is the real integrity
# failure). Verify, refetch once, verify again, then give up loudly.
IMG_CACHE="${CACHE_DIR}/${UBUNTU_IMAGE_NAME}"

fetch_image() {
  echo "[1/5] downloading ${UBUNTU_IMAGE_NAME}"
  curl -fL --progress-bar -o "${IMG_CACHE}.part" "${UBUNTU_IMAGE_URL}"
  mv -f "${IMG_CACHE}.part" "$IMG_CACHE"
}

# Echo the digest we must match, or exit. Re-read per attempt: if the release
# symlink rotates mid-run, the sums we compare against must be the ones that
# belong to the image we just pulled.
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
  # Almost always means Ubuntu respun the release since you last downloaded: the
  # 'release' URL is a symlink to the newest respin. Re-download once, verify again.
  echo "[=] cached image ≠ the published digest (${UBUNTU_RELEASE} was probably respun) — re-downloading once, then verifying again"
  rm -f "$IMG_CACHE"
  fetch_image
  FRESH=1
  WANT="$(expected_sha)"
  ACTUAL_SHA="$(sha256sum "$IMG_CACHE" | cut -d' ' -f1)"
fi

if [[ "$ACTUAL_SHA" != "$WANT" ]]; then
  echo "[!] sha256 MISMATCH on a freshly downloaded image — not a stale cache."
  echo "    expected: $WANT"
  echo "    actual:   $ACTUAL_SHA"
  if [[ -n "${UBUNTU_IMAGE_SHA256:-}" ]]; then
    echo
    echo "    You have UBUNTU_IMAGE_SHA256 pinned. If Ubuntu respun the release,"
    echo "    the pinned image is simply gone from the 'release' symlink — pin the"
    echo "    dated directory too, e.g. in config.local.sh:"
    echo "      UBUNTU_IMAGE_BASE=https://cloud-images.ubuntu.com/releases/${UBUNTU_RELEASE}/release-YYYYMMDD"
    echo "    Otherwise treat this as a real integrity failure and stop."
  else
    echo
    echo "    The image and the sums come from the same directory, so this should"
    echo "    not happen. Do not proceed; investigate."
  fi
  rm -f "$IMG_CACHE"
  exit 1
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

# Token substitution in Python rather than sed: the payloads are base64 blobs
# and a PEM that has to be re-indented to sit under a YAML block scalar, and
# sed replacement text with slashes/newlines in it is a footgun factory.
# /bin/true, not `true`: this lands in runcmd as a YAML list, and a bare `true`
# there parses as the BOOLEAN true, which fails cloud-init's schema
# ("runcmd.N.0: True is not of type 'string'") and makes every single build
# print "[!] cloud-config failed schema validation". Harmless in effect — the
# command still ran — but a warning that is always wrong is a warning you stop
# reading, and that is how a real schema error gets missed.
CUDA_CMD='[/bin/true]'
[[ "$WITH_CUDA" == true ]] && CUDA_CMD='[/usr/local/sbin/kata-install-cuda]'

python3 - "$@" <<PY
import base64, pathlib, sys

guest = pathlib.Path("${GUEST_DIR}")
tpl   = (guest / "cloud-init" / "user-data").read_text()

def b64(p):
    return base64.b64encode(pathlib.Path(p).read_bytes()).decode()

# The CA goes in as text under a YAML block scalar, so every line after the
# first needs the block's indentation (6 spaces, matching the template).
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
    # Only SYSTEM-wide config is baked into the image. The per-user dotfiles
    # (zsh/zshrc, npm/npmrc, fastfetch/*) used to be injected under /home/agent
    # here; that directory is now a virtiofs mountpoint, so they are seeded onto
    # the storage tree host-side by 'kata disk seed' from the same guest/configs.
    # NB: single quotes, not backticks. This heredoc is UNQUOTED (<<PY) so bash
    # expands its body — a backticked comment is executed as a command
    # substitution and its output lands in the Python source. Same for dollar-paren.
    "@@B64_STARSHIP@@":  b64(guest / "configs" / "starship.toml"),
    "@@B64_CUDA@@":      b64(guest / "cuda-install.sh"),
    "@@B64_TOOLS@@":     b64(guest / "tools-install.sh"),
}
for k, v in tokens.items():
    tpl = tpl.replace(k, v)

# Fail loudly on a token we forgot to define — a half-substituted user-data
# produces a guest that boots and is subtly wrong, which is worse than no guest.
# Comment lines are exempt: user-data's own header documents the token syntax,
# and a token left in a comment cannot affect the guest.
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
# The cloud image ships a small root partition; grow it BEFORE the boot so
# cloud-init's growpart/resizefs (which run in this boot, the only one where
# cloud-init is enabled) expand the filesystem to the full size. Sessions layer
# a same-sized overlay on top, so the two must agree.
WIP="${BUILD_DIR}/base.qcow2"
rm -f "$WIP"
qemu-img convert -O qcow2 "$IMG_CACHE" "$WIP"
qemu-img resize "$WIP" "$VM_DISK_SIZE" >/dev/null

SERIAL_LOG="${BUILD_DIR}/build-serial.log"
rm -f "$SERIAL_LOG"
echo "[4/5] provisioning boot (cloud-init), a few minutes${WITH_CUDA:+ and a lot longer with CUDA} — serial log: ${SERIAL_LOG}"

set +e
# Same stripped device surface as a session (threat: qemu-device-surface); the
# option list is in config.sh so the two cannot drift. Both drives are virtio and
# the console is serial, so nothing here wants the defaults.
#
# The ONE difference from vm.sh, and it is deliberate: `-nic user` is SLIRP,
# i.e. exactly the library behind the second escape in
# knowledge/vm-escape-2026-08.md. It stays because this script runs
# UNPRIVILEGED (kata build-base refuses root) and a tap on the bridge needs
# root. The risk is genuinely different — no agent is in the loop, the workload
# is Ubuntu's own cloud image running our cloud-init, and the process is yours
# rather than uid 1001 — but it is still network-facing, which is why
# `threat: no-slirp` is scoped to the session path and says so out loud. If this
# ever gains a privileged variant, move it to the bridge.
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

# The LAST runcmd echoes this straight to /dev/console. Its absence means
# provisioning did not reach the end, whatever qemu's exit code says — a
# half-provisioned base is worse than no base, so fail loudly.
#
# It used to come from `power_state.message`, which does not work: cloud-init
# hands that to `shutdown`, which broadcasts it with wall, and wall reaches only
# logged-in terminals — a headless serial boot has none. Builds provisioned
# correctly and were then declared failed. Don't move the marker back there.
grep -q 'katastrophe base provisioned' "$SERIAL_LOG" || {
  echo "[!] cloud-init did not report completion — base NOT installed."
  echo "    last 40 lines of ${SERIAL_LOG}:"
  tail -40 "$SERIAL_LOG"
  exit 1
}
# Surface provisioning errors even on an otherwise clean run. Two known-benign
# lines are filtered out, because a warning you learn to ignore is worse than no
# warning: `cloud-init clean` (a runcmd) deletes the state directory that the
# later boot-finished write and the log-collection step expect, so both complain
# on every successful build by construction.
if grep -iE 'cloud-init.*(fail|error|traceback)' "$SERIAL_LOG" |
  grep -qvE 'boot finished file|Failed at stage.*modules-final'; then
  echo "[!] cloud-init reported errors during provisioning:"
  grep -inE 'cloud-init.*(fail|error|traceback)' "$SERIAL_LOG" |
    grep -vE 'boot finished file|Failed at stage.*modules-final' | tail -20
  echo "    review ${SERIAL_LOG}; the base was still installed."
fi
# The schema detail is printed to the console by a runcmd, because it only
# exists inside the guest and `clean --logs` deletes it moments later.
if grep -q 'failed schema validation' "$SERIAL_LOG"; then
  echo "[!] cloud-config failed schema validation. Detail from the guest:"
  sed -n '/cloud-init schema/,/^$/p' "$SERIAL_LOG" | tail -20
fi

# --- 5. Install -----------------------------------------------------------
# Into $VM_BASES_DIR, as the base named $VM_BASE_NAME — the SAME namespace
# `--from` and `kata bases` read. It used to go to a separate absolute path
# ($VM_BASE, on the host root fs) while --from looked in $VM_BASES_DIR, so a
# fresh build could sit there invisibly while `--from base` kept booting a
# months-old image out of the other directory. One namespace, no ambiguity.
#
# No sudo: the bases dir is you-owned 0700 in both storage modes (@bases on the
# key, /var/lib/agent-vm/bases locally), which is also what keeps it out of the
# agent's reach (threat: base-poisoning).
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

Warm bases baked from an OLDER version of this one are now stale — 'kata bases'
marks them. Re-bake them off the new one (e.g. --from base --to cuda).

next:
  kata up                             # bridge + nft + proxies
  kata vm --ssh                    # CPU session, detached + ssh
  kata vm --ssh --gpu              # with the passed-through GPU
                                      # (needs: kata gpu-mode sandbox)
EOF
