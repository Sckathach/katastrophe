#!/usr/bin/env bash
# kata-install-cuda — NVIDIA driver + CUDA toolkit inside the sandbox guest.
#
# Baked into every base at /usr/local/sbin/kata-install-cuda. Run it either:
#   * automatically, by passing --cuda to `kata build-base`, or
#   * by hand in a warm base:  sudo kata-install-cuda
#     then `poweroff` and re-bake with `kata vm --from X --to cuda`.
#
# The second shape is usually what you want: it keeps the blank base small and
# fast to rebuild, and CUDA is ~3 GB you rarely need to re-download.
#
# Why the guest driver version is unconstrained by the host's: with VFIO the
# guest owns the physical GPU outright — the host has unbound it from `nvidia`
# and bound it to vfio-pci, so there is no host driver in the path at all. This
# is the opposite of the old CDI/container arrangement, where the container had
# to match the host driver exactly because it was borrowing the host's libs.
#
# Egress note: this needs developer.download.nvidia.com and the Ubuntu archive.
# Both are in proxy/mitmproxy/allowlist.py. If you run it during a session, the
# gate must be up (`kata up`); if you run it during a build, there is no gate.
set -euo pipefail

[[ $EUID -eq 0 ]] || {
  echo "run as root: sudo kata-install-cuda" >&2
  exit 1
}

DISTRO="${DISTRO:-ubuntu2404}"
ARCH="${ARCH:-x86_64}"
KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/${ARCH}/cuda-keyring_1.1-1_all.deb"

echo "[1/3] adding NVIDIA CUDA repository (${DISTRO}/${ARCH})"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/cuda-keyring.deb" "$KEYRING_URL"
dpkg -i "$tmp/cuda-keyring.deb"
apt-get update

# `cuda-drivers` is the meta-package for the proprietary driver; `cuda-toolkit`
# is nvcc + libraries without pulling a second driver copy. Deliberately NOT
# `cuda`, which drags in the samples and docs.
echo "[2/3] installing driver + toolkit (this is the slow part)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  cuda-drivers \
  cuda-toolkit

echo "[3/3] wiring PATH/LD_LIBRARY_PATH"
cat >/etc/profile.d/cuda.sh <<'EOF'
export CUDA_HOME=/usr/local/cuda
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
EOF
chmod 0644 /etc/profile.d/cuda.sh

apt-get clean

echo
echo "[ok] installed. Verify AFTER a reboot with the GPU attached:"
echo "       nvidia-smi"
echo "     If nvidia-smi reports 'no devices', the card was not passed through —"
echo "     check 'kata gpu-mode status' on the HOST and that you used 'kata vm --gpu'."
