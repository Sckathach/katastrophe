#!/usr/bin/env bash
# disk.sh — the encrypted-key utility. A UTILITY, not part of the sandbox.
#
# OPTIONAL: nothing here is required to run a session. It exists so that
# unlocking and mounting a LUKS+btrfs key is one command instead of six, and it
# is a worked example rather than a fixed requirement — any block device
# addressed by UUID works (the author uses a USB key; an internal partition or a
# file-backed loopback is identical). Skip it entirely and point MOUNT_HOME at a
# plain directory if you prefer.
#
# THIS IS THE ONLY FILE THAT KNOWS WHAT A USB, A LUKS VOLUME OR A BTRFS
# SUBVOLUME IS, and that boundary is deliberate (2026-09-13). There used to be a
# KATA_STORAGE mode (`usb` | `local`) that every script resolved, so the sandbox
# itself carried two candidate trees and a flag to pick between them — which is
# how `kata --usb build-base` and `kata vm --from base` came to mean different
# files. Now: disk.sh PREPARES a tree; it does not SELECT between two. The rest
# of the project takes one `$MOUNT_HOME` and stays ignorant of the medium.
#
# Consequence, and it is the point rather than an oversight: this script
# hardcodes /mnt/agent-home and friends below. In shared library code that was
# the thing being deleted; in a utility that sets up one specific key it is just
# a fact about that key. After `kata disk mount`, tell the sandbox where it went:
#
#   MOUNT_HOME="${MOUNT_HOME:-/mnt/agent-home}"   # in config.local.sh (gitignored)
#
# Always in that :- form, never a bare assignment: config.local.sh is sourced
# FIRST, so a hard assignment silently beats `env MOUNT_HOME=... kata ...` and
# every documented way of overriding it for one run.
#
# The *copyable* part is the subvolume ownership model, not the mount plumbing.
# One btrfs filesystem, five sibling subvolumes, each its own /mnt/<name> with
# its own owner/mode. The split *is* the security model: anything that protects
# you *from* the agent (the snapshots) lives on a subvolume the agent uid cannot
# write — never nested under the agent-owned @home.
#
#   subvol      mount                 owner        mode  agent   snapshot
#   @home       /mnt/agent-home       agent:agent  755   rw      yes
#   @state      /mnt/agent-state      agent:agent  700   rw      yes
#   @shared     /mnt/shared-storage   you:you      755   ro      no
#   @bases      /mnt/vm-bases         you:you      700   none    no
#   @snapshots  /mnt/snapshots        root:root    700   none    (holds ro snaps)
#
# Two rows are now ARCHIVE space rather than live sandbox paths, and saying so
# beats leaving you to wonder why nothing appears in them:
#   @bases  warm VM bases moved to $VM_BASES_DIR on the host disk, because they
#           are the half of storage that never varies (system state only, no
#           credentials, never snapshotted). `kata vm --from` looks ONLY there.
#           This subvolume is a fine place to archive a base by hand.
#   @state  has no consumer in the current codebase. It predates the
#           home-as-a-virtiofs-mount change, when the work tree and the agent's
#           persistent state were different places. Kept because it exists on
#           real keys; a deletion candidate.
#
# Subcommands (all need root; `kata disk …` wraps this in sudo):
#   init       create missing subvolumes + set owners/modes (idempotent)
#   mount      unlock LUKS, mount all, snapshot @home+@state, seed dotfiles
#   snap       take an on-demand ro snapshot of @home+@state (before a risky run)
#   seed       copy guest/configs/* dotfiles into $MOUNT_HOME (the guest mounts
#              it as /home/agent, so they can't come from the image).
#              Copy-if-missing; `seed --force` re-pushes the repo's version.
#   umount     unmount all, close LUKS
#   local-init create a plain-directory tree on the host disk with the same
#              ownership classes, for when you are not using a key. No btrfs, so
#              no snapshots and no rollback — that is the trade, stated at run
#              time.
#   reset     DESTROY every subvolume and recreate fresh (asks for confirmation)
#   rollback  roll @home back to a chosen pre-session snapshot
#   status    show what's mounted + the subvolume/snapshot inventory
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

die() {
  echo "disk: $*" >&2
  exit 1
}

DEV="/dev/disk/by-uuid/${AGENT_DEV_UUID}"

# The key's own mountpoints. Local to this script on purpose (see the header):
# config.sh declares what the SANDBOX uses, this declares what the KEY offers,
# and config.local.sh is where you say that one of these is the other.
USB_HOME="${USB_HOME:-/mnt/agent-home}"
USB_STATE="${USB_STATE:-/mnt/agent-state}"
USB_SHARED="${USB_SHARED:-/mnt/shared-storage}"
USB_BASES="${USB_BASES:-/mnt/vm-bases}"
USB_SNAPS="${USB_SNAPS:-/mnt/snapshots}"

# name | mountpoint | owner:group | mode | extra mount opts | snapshot?
subvol_rows() {
  cat <<EOF
@home|${USB_HOME}|${AGENT_USER}:${AGENT_USER}|755|compress=zstd:3,noatime|yes
@state|${USB_STATE}|${AGENT_USER}:${AGENT_USER}|700|compress=zstd:3,noatime|yes
@shared|${USB_SHARED}|${HOST_USER}:${HOST_USER}|755|compress=zstd:3,noatime|no
@bases|${USB_BASES}|${HOST_USER}:${HOST_USER}|700|compress=zstd:3,noatime|no
@snapshots|${USB_SNAPS}|root:root|700||no
EOF
}

preflight() {
  [[ $EUID -eq 0 ]] || die "run as root (kata disk … wraps this in sudo)"
  [[ -n "$AGENT_DEV_UUID" ]] || die "AGENT_DEV_UUID unset — set it in config.local.sh (see config.sh)"
  [[ -n "$HOST_USER" ]] || die "HOST_USER unset — run via sudo so SUDO_USER is set"
  id -u "$AGENT_USER" >/dev/null 2>&1 || die "agent user '$AGENT_USER' does not exist"
  [[ -b "$DEV" ]] || die "device $DEV not present (USB plugged in?)"
}

open_luks() {
  [[ -b "$AGENT_MAPPER" ]] || cryptsetup open "$DEV" "$AGENT_MAPPER_NAME"
}

# Mount the btrfs top (subvolid=5) at a temp dir; echo the dir. Caller unmounts.
mount_top() {
  local top
  top="$(mktemp -d)"
  mount -o subvolid=5 "$AGENT_MAPPER" "$top"
  echo "$top"
}

any_mounted() {
  local sv mp _
  while IFS='|' read -r sv mp _; do
    mountpoint -q "$mp" && return 0
  done < <(subvol_rows)
  return 1
}

# --- subcommands ----------------------------------------------------------

cmd_init() {
  preflight
  open_luks
  local top
  top="$(mount_top)"
  trap 'umount "$top" 2>/dev/null; rmdir "$top" 2>/dev/null' RETURN
  local sv mp owner mode _x _s
  while IFS='|' read -r sv mp owner mode _x _s; do
    local verb="exists"
    if [[ ! -d "${top}/${sv}" ]]; then
      btrfs subvolume create "${top}/${sv}" >/dev/null
      verb="created"
    fi
    chown "$owner" "${top}/${sv}"
    chmod "$mode" "${top}/${sv}"
    echo "[+] ${sv} ${verb} → ${mp}  ${owner} ${mode}"
  done < <(subvol_rows)
  echo "[ok] subvolumes ready. Next: kata disk mount"
}

cmd_mount() {
  preflight
  open_luks
  local sv mp owner mode extra snap
  while IFS='|' read -r sv mp owner mode extra snap; do
    mkdir -p "$mp"
    mountpoint -q "$mp" && continue
    local opts="nodev,nosuid${extra:+,$extra},subvol=${sv}"
    mount -o "$opts" "$AGENT_MAPPER" "$mp"
  done < <(subvol_rows)

  snap_subvols
  # Seed the KEY's home, not $MOUNT_HOME: this subcommand is about the key by
  # definition, and if config.local.sh does not point MOUNT_HOME here yet then
  # seeding that instead would quietly populate the wrong tree.
  seed_home false "$USB_HOME"
  echo "[ok] storage mounted. Pre-session snapshots tagged pre-${SNAP_TS}."
  # Report EVERY subvolume the sandbox is configured to look elsewhere for, not
  # just the home. Checking one of the two was worse than checking neither: it
  # reads as "storage config is verified" while $SHARED_STORAGE_DIR silently
  # pointed at an empty /var/lib dir and every project repo sat unused on the
  # key (found 2026-09-13, six repos, since August). Same family as the two base
  # namespaces — one workflow, two trees, nothing saying they disagreed.
  # One line, like every other log here: this fires on every mount that does not
  # use the key for everything, which is the normal case, and an eight-line block
  # repeated twice is how a warning becomes wallpaper. The `fix:` token is the
  # refusal convention (lib.sh) reused so it stays greppable. The `:-` form in
  # the suggested line is not decoration — config.local.sh is sourced first, so a
  # bare assignment silently kills every environment override (tests/unit.sh C1).
  divergence() { # divergence <var name> <configured> <on the key>
    [[ "$2" != "$3" ]] || return 0
    echo "[!] ${1} is ${2}, not this key's ${3} — fix: add ${1}=\"\${${1}:-${3}}\" to ${REPO_ROOT}/config.local.sh"
  }
  divergence MOUNT_HOME "$MOUNT_HOME" "$USB_HOME"
  divergence SHARED_STORAGE_DIR "$SHARED_STORAGE_DIR" "$USB_SHARED"
}

# --- Dotfile seeding ------------------------------------------------------
# The guest mounts $MOUNT_HOME AS /home/agent, so nothing under the guest's home
# comes from the image any more — a dotfile baked in there would be shadowed by
# the mount and then drift from the real copy. guest/configs/ is the single
# source of truth and gets copied out to each storage tree instead. Two
# destinations, one repo: /mnt/agent-home (usb) and /home/agent (local).
#
# COPY-IF-MISSING by default, so calling it from `mount` and `local-init` can
# never clobber an edit made inside a session. `kata disk seed --force`
# re-pushes the repo's version over whatever is there; if the two have both
# moved, that is a manual merge, deliberately (there is no sane automatic
# answer, and guessing would lose work).
#
# repo-relative source | path under the home | mode
seed_rows() {
  cat <<EOF
configs/zsh/zshrc|.zshrc|644
configs/npm/npmrc|.npmrc|644
configs/fastfetch/config.jsonc|.config/fastfetch/config.jsonc|644
configs/fastfetch/logo.ans|.config/fastfetch/logo.ans|644
configs/fastfetch/word.txt|.config/fastfetch/word.txt|644
configs/agents/AGENTS.md|.agents/AGENTS.md|644
EOF
}

# Every agent CLI looks for its instructions under a different name, so one file
# is pointed at from all of them rather than copied. ~/.agents/AGENTS.md is the
# real file (seeded above, on the persistent home, agent-owned and editable);
# these are symlinks to it.
#
# Deliberately NOT baked into the image even though it documents the image's
# tools: /home/agent is a virtiofs mountpoint at session time, so an image copy
# would be shadowed by the share and then diverge from the one actually read.
# `kata-install-tools --check` is what keeps the doc honest instead.
#
# link path under the home | target (relative to the home)
seed_link_rows() {
  cat <<EOF
.claude/CLAUDE.md|.agents/AGENTS.md
.codex/AGENTS.md|.agents/AGENTS.md
EOF
}

# THE LINKS MUST BE RELATIVE. They are created here, on the host, where the tree
# is `$MOUNT_HOME` (e.g. /mnt/agent-home) — and they are *resolved* inside the
# guest, where the very same tree is virtiofs-mounted at /home/agent. An absolute
# target is therefore correct in exactly one of the two namespaces. It used to be
# `${home}/${target}`, so every link dangled in the guest and only `agy` (which
# reads ~/.agents/AGENTS.md directly, never through a link) picked the file up;
# Claude Code and Codex silently loaded nothing. Found 2026-09-13.
#
# General rule for anything seeded host-side: NEVER embed the host's absolute
# path in content the guest reads. One tree, two names for it.
seed_links() {
  local home="$1" force="$2" link target from dir up rel n=0
  while IFS='|' read -r link target; do
    from="${home}/${link}"
    dir="$(dirname "$link")"
    # ../ per component between the link's directory and the home, so the target
    # is reached without ever naming the root of the tree.
    up=""
    if [[ "$dir" != "." ]]; then
      local c
      for c in ${dir//\// }; do up+="../"; done
    fi
    rel="${up}${target}"
    # A symlink is a POINTER, so a stale one is ours to correct — that is what
    # makes this bug self-healing on the next `kata disk seed`, with no --force
    # (which would also re-push dotfiles over in-guest edits). A regular file is
    # CONTENT: the agent or you replaced the link deliberately, so leave it.
    if [[ -L "$from" && "$(readlink "$from")" != "$rel" ]]; then rm -f "$from"; fi
    if [[ -e "$from" || -L "$from" ]] && [[ "$force" != true ]]; then continue; fi
    install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$(dirname "$from")"
    chown_chain "$home" "$(dirname "$from")"
    ln -sfn "$rel" "$from"
    # A symlink's own ownership is what matters for replacing it later; -h so we
    # chown the link and not the file it points at.
    chown -h "${AGENT_USER}:${AGENT_USER}" "$from"
    echo "[seed] ${link} -> ${rel}"
    n=$((n + 1))
  done < <(seed_link_rows)
  return 0
}

# Give the agent every directory between $home and $1. `install -D` creates
# missing parents as ROOT, and chowning only the immediate one leaves e.g.
# ~/.config root-owned while ~/.config/fastfetch is fine — which looks correct
# until the agent tries to create ~/.config/nvim inside the guest and gets
# EACCES in its own home. Walk the whole chain.
chown_chain() {
  local home="$1" dir="$2"
  while [[ "$dir" == "$home"/* ]]; do
    chown "${AGENT_USER}:${AGENT_USER}" "$dir"
    dir="$(dirname "$dir")"
  done
  return 0
}

# Your public key into the agent home, so `kata ssh` doesn't ask for the guest
# password once per terminal — which stops being a curiosity the moment the VM
# outlives one ssh session and you keep three open.
#
# Safe in the direction that matters: a PUBLIC key grants login TO the sandbox,
# never anything out of it. The agent owns this file and can rewrite it at will;
# all that buys it is deciding who may ssh into the box it already controls.
# Nothing here forwards an agent socket or a private key into the guest — don't
# add `ssh -A` to ssh.sh for the same reason.
seed_ssh_key() {
  local home="$1" force="$2" pub="" c
  local hhome
  hhome="$(getent passwd "${HOST_USER}" | cut -d: -f6)"
  [[ -n "$hhome" ]] || return 0
  # $KATA_SSH_KEY_NAME first — a purpose-named key you can revoke without
  # touching whatever else your default identity is trusted by. The stock names
  # stay as a fallback so an existing setup keeps working.
  for c in "${KATA_SSH_KEY_NAME}.pub" id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
    if [[ -r "${hhome}/.ssh/${c}" ]]; then
      pub="${hhome}/.ssh/${c}"
      break
    fi
  done
  [[ -n "$pub" ]] || {
    echo "[seed] no ssh public key for ${HOST_USER} — 'kata ssh' will ask for the guest password"
    return 0
  }
  local auth="${home}/.ssh/authorized_keys"
  if [[ -e "$auth" && "$force" != true ]]; then
    # Say so rather than skipping in silence. Switching to a purpose-named key
    # is a thing people do once, and the symptom of this being quiet is "kata
    # ssh still asks for a password and I cannot see why". `seed --force` is the
    # wrong answer here — it re-pushes EVERY row, including a .zshrc an agent
    # may have appended to inside a session — so name the targeted command.
    if ! cmp -s "$pub" "$auth"; then
      echo "[seed] .ssh/authorized_keys differs from ${pub##*/}, left alone — fix: sudo install -o ${AGENT_USER} -g ${AGENT_USER} -m 600 ${pub} ${auth}"
    fi
    return 0
  fi
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 700 "${home}/.ssh"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 600 "$pub" "$auth"
  echo "[seed] .ssh/authorized_keys  (from ${pub})"
  return 0
}

# seed_home [force] [home]
# The home is an ARGUMENT, not $MOUNT_HOME: `mount` seeds the key's @home while
# `seed`/`local-init` seed the configured one, and those can differ.
seed_home() {
  local force="${1:-false}" home="${2:-$MOUNT_HOME}"
  [[ -d "$home" ]] || die "$home does not exist — mount the key, or use local-init"
  local src dst mode from to n=0 skipped=0
  while IFS='|' read -r src dst mode; do
    from="${REPO_ROOT}/guest/${src}"
    to="${home}/${dst}"
    [[ -f "$from" ]] || die "missing source config: $from"
    if [[ -e "$to" && "$force" != true ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    install -D -o "$AGENT_USER" -g "$AGENT_USER" -m "$mode" "$from" "$to"
    chown_chain "$home" "$(dirname "$to")"
    echo "[seed] ${dst}"
    n=$((n + 1))
  done < <(seed_rows)
  seed_links "$home" "$force"
  seed_ssh_key "$home" "$force"
  if [[ $skipped -gt 0 ]]; then
    echo "[seed] ${n} written, ${skipped} already present (--force to overwrite)"
  fi
}

cmd_seed() {
  [[ $EUID -eq 0 ]] || die "run as root (kata disk seed)"
  id -u "$AGENT_USER" >/dev/null 2>&1 || die "agent user '$AGENT_USER' does not exist"
  # if-block, not `[[ … ]] && force=true`: a false test there is the last
  # statement's exit status and `set -e` would kill the script (lib.sh style rule).
  local force=false
  if [[ "${1:-}" == "--force" ]]; then force=true; fi
  echo "[*] seeding ${MOUNT_HOME}"
  require_storage "$MOUNT_HOME"
  seed_home "$force" "$MOUNT_HOME"
}

# Take a read-only pre-session snapshot of each snapshot-eligible subvol into
# @snapshots, tagged with one shared UTC timestamp (exported as SNAP_TS). Used
# by `mount` (once per USB-mount) and by `snap` (on-demand, before risky runs).
snap_subvols() {
  SNAP_TS="$(date -u +%Y%m%dT%H%M%SZ)"
  local sv mp owner mode extra snap
  while IFS='|' read -r sv mp owner mode extra snap; do
    [[ "$snap" == yes ]] || continue
    mountpoint -q "$mp" || die "$mp not mounted — run 'kata disk mount' first"
    btrfs subvolume snapshot -r "$mp" "${USB_SNAPS}/${sv#@}-pre-${SNAP_TS}" >/dev/null
    echo "[snap] ${sv#@} → ${USB_SNAPS}/${sv#@}-pre-${SNAP_TS}"
  done < <(subvol_rows)
}

cmd_snap() {
  preflight
  open_luks
  snap_subvols
  echo "[ok] snapshot taken (tag pre-${SNAP_TS}). Roll back with 'kata disk rollback'."
}

# NOTE: grant_gpu_acls/revoke_gpu_acls used to live here. They setfacl'd
# `u:agent:rw` onto /dev/nvidia* on every mount, so the rootless GPU container
# (which ran as uid 1001 on the host) could reach the driver. That runtime is
# gone, and the thing that runs as uid 1001 now is qemu after its privilege
# drop — so those ACLs were handing an escaped qemu direct ioctl access to the
# NVIDIA driver, i.e. the exact ring-0 surface (K.2) that VFIO exists to remove
# from the host side. Deleted 2026-08-01. Do not reintroduce: with VFIO the
# host doesn't touch the GPU at all while the sandbox holds it.
#
# Cleanup of ACLs an older checkout already set lives in net-up.sh
# (strip_agent_dev_acls) — it runs as root once per boot, which is both earlier
# and more reliable than a mount hook that only fires when you use the USB.

cmd_umount() {
  preflight
  if pgrep -u "$AGENT_USER" >/dev/null 2>&1; then
    echo "agent processes still running:"
    ps -u "$AGENT_USER" -o pid,comm
    read -r -p "SIGTERM them? [y/N] " ans
    [[ "$ans" == y ]] || die "aborting — stop them, then re-run"
    pkill -TERM -u "$AGENT_USER" || true
    sleep 2
    pkill -KILL -u "$AGENT_USER" || true
  fi
  # Unmount in reverse so @snapshots (snapshot target) goes last-ish; order is
  # independent here (siblings), but reverse is tidy.
  local sv mp _
  local mps=()
  while IFS='|' read -r sv mp _; do mps+=("$mp"); done < <(subvol_rows)
  local i
  for ((i = ${#mps[@]} - 1; i >= 0; i--)); do
    mountpoint -q "${mps[$i]}" && umount "${mps[$i]}"
  done
  [[ -b "$AGENT_MAPPER" ]] && cryptsetup close "$AGENT_MAPPER_NAME"
  echo "[ok] storage closed."
}

cmd_reset() {
  preflight
  any_mounted && die "subvolumes still mounted — run 'kata disk umount' first"
  echo "!! This DESTROYS every subvolume on ${AGENT_MAPPER} (all agent work,"
  echo "!! state, bases, and snapshots). Projects in your \$HOME are untouched."
  read -r -p "Type DESTROY to proceed: " ans
  [[ "$ans" == DESTROY ]] || die "aborted"
  open_luks
  local top
  top="$(mount_top)"
  trap 'umount "$top" 2>/dev/null; rmdir "$top" 2>/dev/null' RETURN
  # Delete deepest-first (by path depth) so nested snapshots go before their
  # parent subvol — btrfs refuses to delete a subvol that still contains one.
  local p
  btrfs subvolume list "$top" | awk '{print $NF}' |
    awk -F/ '{print NF-1, $0}' | sort -rn | cut -d' ' -f2- |
    while read -r p; do
      [[ -n "$p" ]] && {
        btrfs subvolume delete "${top}/${p}" >/dev/null
        echo "[-] deleted $p"
      }
    done
  # Recreate fresh (reuse the same create+chown logic against the open top).
  local sv mp owner mode _x _s
  while IFS='|' read -r sv mp owner mode _x _s; do
    btrfs subvolume create "${top}/${sv}" >/dev/null
    chown "$owner" "${top}/${sv}"
    chmod "$mode" "${top}/${sv}"
    echo "[+] $sv ($owner $mode)"
  done < <(subvol_rows)
  echo "[ok] wiped + recreated. Next: kata disk mount"
}

cmd_rollback() {
  preflight
  mountpoint -q "$USB_SNAPS" || die "$USB_SNAPS not mounted — run 'kata disk mount' first"
  pgrep -u "$AGENT_USER" >/dev/null 2>&1 && die "agent still has processes — 'kata disk umount' then 'mount' first"
  echo "@home snapshots in ${USB_SNAPS}:"
  ls -1 "$USB_SNAPS" | grep '^home-pre-' | nl
  read -r -p "snapshot name (e.g. home-pre-20260626T...Z): " snapname
  local src="${USB_SNAPS}/${snapname}"
  [[ -d "$src" ]] || die "$src does not exist"
  umount "$USB_HOME"
  local top
  top="$(mount_top)"
  local dirty="@home-dirty-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "${top}/@home" "${top}/${dirty}"
  btrfs subvolume snapshot "${top}/@snapshots/${snapname}" "${top}/@home" >/dev/null
  chown "${AGENT_USER}:${AGENT_USER}" "${top}/@home"
  chmod 755 "${top}/@home"
  umount "$top"
  rmdir "$top"
  mount -o "nodev,nosuid,compress=zstd:3,noatime,subvol=@home" "$AGENT_MAPPER" "$USB_HOME"
  echo "[ok] @home rolled back to ${snapname}; old @home kept as ${dirty} — delete it with 'kata disk reset' or a manual top mount"
}

cmd_status() {
  [[ -n "$AGENT_DEV_UUID" ]] || die "AGENT_DEV_UUID unset (config.local.sh)"
  echo "device: $DEV  mapper: $AGENT_MAPPER  ($([[ -b "$AGENT_MAPPER" ]] && echo open || echo closed))"
  local sv mp _
  while IFS='|' read -r sv mp _; do
    printf '  %-26s %s\n' "$mp" "$(mountpoint -q "$mp" && echo mounted || echo '—')"
  done < <(subvol_rows)
  if [[ -d "$USB_SNAPS" ]] && mountpoint -q "$USB_SNAPS"; then
    echo "snapshots:"
    ls -1 "$USB_SNAPS" 2>/dev/null | sed 's/^/  /'
  fi
  # The two paths that matter to the sandbox, so a mounted key that nothing is
  # using is visible here rather than inferred.
  echo "sandbox is configured to use:"
  printf '  %-26s %s\n' "$MOUNT_HOME" \
    "home$([[ "$MOUNT_HOME" == "$USB_HOME" ]] && echo ' (this key)' || echo ' (NOT this key)')"
  printf '  %-26s %s\n' "$VM_BASES_DIR" "bases (always the host disk; @bases is archive space)"
}

# --- Plain-directory tree (no key) ----------------------------------------
# Creates the ownership classes the security model depends on, on ordinary
# directories, at whatever paths config.sh currently names. So this is not a
# second storage MODE — it is `mkdir` + `chown` for the paths you already
# configured, and if those happen to be the key's mountpoints it refuses rather
# than chowning someone else's subvolume.
#
#   $MOUNT_HOME           agent:agent 755  agent rw, YOU ro
#     755 not 700, on purpose: `git fetch $MOUNT_HOME/proj` is the sanctioned
#     return path and you need to traverse it. The agent's privacy from you is
#     not part of the threat model — the reverse is.
#   $VM_BASES_DIR         you:you 700  agent NONE
#     Under /var/lib, never under the agent home: vm.sh parses these as root, so
#     an agent-writable base would be a root-code-exec surface
#     (threat: base-poisoning).
#   $SHARED_STORAGE_DIR   you:you 755  agent ro
#
# What a plain tree gives up versus a LUKS+btrfs key: snapshots and
# `kata disk rollback` (both btrfs features), and REMOVABILITY — the point of the
# key is that you can pull it out and walk away, whereas the laptop's own disk is
# unlocked for as long as you are logged in. Note what is NOT on that list:
# encryption at rest, which the host root filesystem may well already have (check
# with `findmnt -no SOURCE /` — a /dev/mapper/luks-* answer means it does). The
# old text here claimed otherwise and was simply wrong on this machine.
cmd_local_init() {
  [[ $EUID -eq 0 ]] || die "run as root (kata disk local-init)"
  [[ -n "$HOST_USER" ]] || die "HOST_USER unset — run via sudo so SUDO_USER is set"
  id -u "$AGENT_USER" >/dev/null 2>&1 || die "agent user '$AGENT_USER' does not exist"

  # dir | owner:group | mode
  local rows=(
    "${MOUNT_HOME}|${AGENT_USER}:${AGENT_USER}|755"
    "${AGENT_WORK_DIR}|${AGENT_USER}:${AGENT_USER}|755"
    "${SHARED_STORAGE_DIR}|${HOST_USER}:${HOST_USER}|755"
    "${SHARED_SRC_DIR}|${HOST_USER}:${HOST_USER}|755"
    "${VM_BASES_DIR}|${HOST_USER}:${HOST_USER}|700"
  )
  local row d owner mode
  for row in "${rows[@]}"; do
    IFS='|' read -r d owner mode <<<"$row"
    # A mountpoint here means these paths are the key's, and this subcommand
    # would be reconfiguring it by mistake.
    mountpoint -q "$d" && die "$d is a mountpoint — that is a mounted volume, not a plain tree"
    install -d -o "${owner%%:*}" -g "${owner##*:}" -m "$mode" "$d"
    printf '  %-28s %-16s %s\n' "$d" "$owner" "$mode"
  done

  seed_home false "$MOUNT_HOME"

  cat <<EOF

[ok] storage ready:
    home   ${MOUNT_HOME}
    bases  ${VM_BASES_DIR}
    shared ${SHARED_STORAGE_DIR}

    kata vm --ssh

NOT available on a plain tree: snapshots and 'kata disk rollback' (both are
btrfs features), and you cannot unplug it. If you are about to do something you
might want to undo, put the home on the key instead: 'sudo kata disk mount',
then MOUNT_HOME="\${MOUNT_HOME:-${USB_HOME}}" in config.local.sh.
EOF
}

sub="${1:-}"
shift || true
case "$sub" in
init) cmd_init ;;
mount) cmd_mount ;;
snap) cmd_snap ;;
seed) cmd_seed "$@" ;;
umount) cmd_umount ;;
reset) cmd_reset ;;
rollback) cmd_rollback ;;
status) cmd_status ;;
local-init) cmd_local_init ;;
-h | --help | "")
  echo "usage: disk {init|mount|snap|seed|umount|reset|rollback|status|local-init}"
  echo "       seed [--force]   copy guest/configs dotfiles into the agent home"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
