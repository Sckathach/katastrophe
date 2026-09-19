#!/usr/bin/env bash
# Shell toolbox for the guest. Baked into the image as
# /usr/local/sbin/kata-install-tools and run once by cloud-init during
# `kata build-base`; see guest/configs/agents/AGENTS.md for the doc an agent
# actually reads, and keep the two in sync.
#
#   kata-install-tools            install everything missing, report, exit 0
#   kata-install-tools --check    verify only, exit 1 if anything is missing
#
# WHY AT BUILD TIME AND NOT IN A SESSION. The provisioning boot runs on plain
# qemu SLIRP with NAT and no proxy — `kata build-base` needs neither `kata up`
# nor the allowlist. Installing here therefore costs ZERO new allowlist hosts.
# Doing the same thing inside a session would need four: index.crates.io and
# static.crates.io (cargo-binstall's version lookup and its compile fallback),
# proxy.golang.org and sum.golang.org (`go install`). Every allowlisted host is
# a channel *out* of the sandbox, so buying four permanent ones to pay for a
# one-time install is a bad trade. Add tools here and rebuild the base.
#
# NOTHING MAY BE INSTALLED UNDER /home/agent. That path is a virtiofs mountpoint
# at session time, so anything written there during the build is shadowed by the
# share and silently diverges from the copy that actually gets used. Hence the
# explicit CARGO_INSTALL_ROOT / GOBIN / PIPX_HOME below — every default for
# those three would have landed in a home directory.
#
# MISSING TOOLS ARE NOT FATAL HERE, on purpose: a flaky cargo-binstall should
# not throw away a 20-minute image build. The build prints what is missing and
# `kata-install-tools --check` is the gate you can run any time afterwards.
set -euo pipefail
[[ $EUID -eq 0 ]] || {
  echo "run as root (sudo kata-install-tools)" >&2
  exit 1
}

CHECK_ONLY=false
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

export DEBIAN_FRONTEND=noninteractive
# cloud-init's runcmd does not reliably export HOME, and the cargo-binstall
# bootstrap installs into $HOME/.cargo/bin — with HOME unset it would write to
# the cwd or fail outright.
export HOME="${HOME:-/root}"
export CARGO_INSTALL_ROOT=/usr/local GOBIN=/usr/local/bin
export PATH="/usr/local/bin:/usr/local/go/bin:$PATH"

# The contract. `--check` verifies exactly this list, and AGENTS.md documents
# exactly this list — if you add a tool, add it in all three places.
EXPECT=(rg fd sd ast-grep tree dasel jq mlr sqlite3 xh monolith websocat grpcurl
  watchexec just pre-commit hyperfine shellcheck shfmt eslint lsof strace
  procs btm dust duf tokei)

have() { command -v "$1" >/dev/null 2>&1; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }

report() { # -> 0 if all present, 1 otherwise
  local b missing=()
  for b in "${EXPECT[@]}"; do have "$b" || missing+=("$b"); done
  # dasel v1 and v3 take incompatible flags (-f/-r/-w vs -i/-o) and AGENTS.md
  # documents v3, so a v1 binary is worse than none: the documented invocation
  # fails in a way that looks like a broken tool rather than a wrong version.
  #
  # EXERCISE THE FLAGS, don't parse --version. `go install …/dasel/v3/…@master`
  # produces a binary that reports `dev` (the version is injected by ldflags at
  # release time and master has none), so a version-string grep warns about a
  # perfectly good v3 binary. It cannot be anything else: Go module semantics
  # require a /v3 import path to resolve to v3.x. Same lesson as `kata status` —
  # a functional check beats reading a label.
  if have dasel && ! echo '{"a":1}' | dasel -i json -o yaml >/dev/null 2>&1; then
    warn "dasel does not accept the -i/-o flags AGENTS.md documents (v1 binary?)"
  fi
  if ((${#missing[@]})); then
    warn "MISSING ${#missing[@]}/${#EXPECT[@]}: ${missing[*]}"
    return 1
  fi
  echo "all ${#EXPECT[@]} tools present"
  return 0
}

if [[ "$CHECK_ONLY" == true ]]; then
  report
  exit $?
fi

# --- apt ------------------------------------------------------------------
# Retry individually on a batch failure: one unavailable package otherwise
# takes the whole batch down, and which packages exist varies by release and by
# whether universe is enabled.
native() {
  apt-get install -y --no-install-recommends "$@" && return 0
  warn "batch failed, retrying individually"
  local p
  for p in "$@"; do
    apt-get install -y --no-install-recommends "$p" || warn "unavailable: $p"
  done
  return 0
}

apt-get update
apt-get install -y --no-install-recommends software-properties-common || true
add-apt-repository -y universe || true
apt-get update

native ca-certificates curl git build-essential nodejs npm golang-go pipx \
  ripgrep fd-find tree jq miller sqlite3 lsof strace shellcheck \
  hyperfine just tokei shfmt duf
# Debian renames fd to dodge a package clash. The image's cloud-init does this
# too; harmless to repeat, and needed when this script is run standalone.
if ! have fd && [[ -x /usr/bin/fdfind ]]; then
  ln -sf /usr/bin/fdfind /usr/local/bin/fd
fi

# --- cargo (prebuilt binaries via cargo-binstall) -------------------------
# binstall pulls release artifacts from GitHub rather than compiling, which is
# the difference between seconds and twenty minutes per crate. Source compile is
# the fallback only.
CARGO=(sd:sd ast-grep:ast-grep xh:xh monolith:monolith websocat:websocat
  watchexec-cli:watchexec just:just hyperfine:hyperfine procs:procs
  bottom:btm du-dust:dust tokei:tokei)
need=()
for e in "${CARGO[@]}"; do have "${e#*:}" || need+=("${e%%:*}"); done
if ((${#need[@]})); then
  if ! have cargo-binstall; then
    curl -fsSL https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh |
      bash || true
    if [[ -x "$HOME/.cargo/bin/cargo-binstall" ]]; then
      install -m755 "$HOME/.cargo/bin/cargo-binstall" /usr/local/bin/
    fi
  fi
  if have cargo-binstall; then
    cargo-binstall -y --install-path /usr/local/bin "${need[@]}" || warn "some binstalls failed"
  else
    warn "no cargo-binstall; compiling from source (slow)"
    have cargo || native cargo
    cargo install --locked --root /usr/local "${need[@]}" || warn "some cargo installs failed"
  fi
fi

# --- go -------------------------------------------------------------------
declare -A GOMOD=(
  [dasel]=github.com/tomwright/dasel/v3/cmd/dasel@master
  [duf]=github.com/muesli/duf@latest
  [grpcurl]=github.com/fullstorydev/grpcurl/cmd/grpcurl@latest
  [shfmt]=mvdan.cc/sh/v3/cmd/shfmt@latest
  [mlr]=github.com/johnkerl/miller/v6/cmd/mlr@latest
)
for b in "${!GOMOD[@]}"; do
  have "$b" && continue
  have go || native golang-go
  go install "${GOMOD[$b]}" || warn "go install $b failed"
done

# --- npm / pipx -----------------------------------------------------------
# npm runs as root here, so it uses the DEFAULT global prefix and lands in the
# image. It must not pick up the agent's ~/.npmrc (which points at
# ~/.npm-global, i.e. the virtiofs home) — that would put a baked tool on the
# storage tree where the agent can rewrite it.
have eslint || npm install -g eslint || warn "npm install eslint failed"
have pre-commit || PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin \
  pipx install pre-commit || warn "pipx install pre-commit failed"

# --- report (never fatal; see the header) ---------------------------------
report || warn "run 'sudo kata-install-tools' again, or rebuild the base"
exit 0
