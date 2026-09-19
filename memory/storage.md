# Storage: one tree, five subvolumes, and the ownership classes

The split **is** the security model: anything that protects you *from* the agent
(snapshots, VM bases) lives where the agent uid cannot write. Read this before
changing a path, and before adding any flag that selects between two of them.

## The layout (`scripts/disk.sh`, `kata disk`)

One LUKS+btrfs filesystem, **five sibling subvolumes**, each its own `/mnt/<name>`
with its own owner/mode. The split _is_ the security model: anything that
protects you _from_ the agent (snapshots, VM bases) lives on a subvolume the
agent uid can't write — never nested under the agent-owned `@home`.

| subvol       | mount                 | owner         | mode | agent | snapshot         |
| ------------ | --------------------- | ------------- | ---- | ----- | ---------------- |
| `@home`      | `/mnt/agent-home`     | `agent:agent` | 755  | rw    | yes              |
| `@state`     | `/mnt/agent-state`    | `agent:agent` | 700  | rw    | yes              |
| `@shared`    | `/mnt/shared-storage` | you           | 755  | ro    | no               |
| `@bases`     | `/mnt/vm-bases`       | you           | 700  | none  | no               |
| `@snapshots` | `/mnt/snapshots`      | `root:root`   | 700  | none  | (holds ro snaps) |

`kata disk {init|mount|seed|umount|reset|rollback|status}`. `mount` takes a
read-only pre-session snapshot of `@home` + `@state` into `@snapshots`, then
seeds dotfiles (below).

**`kata disk seed` — dotfiles are copied out, not baked in (2026-08-02).**
`guest/configs/{zsh/zshrc,npm/npmrc,fastfetch/*}` used to be base64'd into
`user-data` and written to `/home/agent` on the provisioning boot. That
directory is a mountpoint now, so they are installed onto the storage tree
host-side instead — `guest/configs/` stays the single source of truth, with two
destinations (`/mnt/agent-home` and `/home/agent`). `mount` and `local-init`
call it; it is **copy-if-missing**, so it can never clobber an edit made inside
a session. It chowns **every** directory it created between the home and the
file, not just the immediate parent — the bug that fixed: `~/.config` stayed
root-owned while `~/.config/fastfetch` looked fine, so the agent got EACCES
creating `~/.config/nvim` in its own home. `seed --force` re-pushes the repo's version; if both sides moved,
that is a manual merge, deliberately — one repo, two places, no sane automatic
answer. Only *system*-wide config (`/etc/zsh/zshrc`, `/etc/starship.toml`,
`/etc/environment`) is still baked into the image, because that survives the
mount. `@bases`/`@snapshots`
out of agent reach is the `threat: base-poisoning` hardening (vm.sh parses base
qcow2s as root, so
an agent-writable base is a root-code-exec surface). `AGENT_DEV_UUID` lives in
`config.local.sh` (gitignored), not `config.sh`. Mirror classes: `@home`/`@state`
are agent-rw/you-ro; `@shared`/`@bases` are you-rw/agent-ro — bridged only by the
`kata project` git interchange, never a shared-writable path.

**There is ONE storage tree and NO mode** (2026-09-13, step 3 of the
simplification pass — `fac24d4`). `$MOUNT_HOME` is a plain constant in
`config.sh`, named once per machine in `config.local.sh`, and
`kata vm --home PATH` overrides it for a single run. `$VM_BASES_DIR` is a
constant too (`/var/lib/agent-vm/bases`, always the host disk).

What was deleted and must not come back: `KATA_STORAGE` (`local`|`usb`), the
global `--usb` flag and the `sudo env KATA_STORAGE=…` threading that carried it
into every script, `storage_paths`, `storage_banner`, the `_kata_*` pin
machinery, and `AGENT_STATE_DIR`.

**Why a mode was the bug rather than merely verbose**, because this is the part
to internalise before adding a flag of your own: a mode bundles two independent
questions into one boolean, and then the two halves of one workflow can answer it
differently with nothing reporting the disagreement. `kata disk mount` followed
by a `kata vm` without `--usb` used a *different home*. `kata --usb build-base`
wrote a base that `kata vm --from base` could not see — and that one presented as
three unrelated guest defects for an afternoon. The previous attempt at a fix was
a louder banner announcing which tree had won; the actual fix is having no second
candidate to be wrong about. Bases get a constant because they are the half of
storage that never varies (system state only, no credentials since the home
became a virtiofs mount, never snapshotted); the home gets the flag because it is
the half that does.

Things to keep straight:

- **`scripts/disk.sh` is the ONLY file that knows what a USB, a LUKS volume or a
  btrfs subvolume is.** It declares its own mountpoints (`USB_HOME`, `USB_STATE`,
  `USB_SHARED`, `USB_BASES`, `USB_SNAPS`) and *prepares* a tree; it does not
  *select* between two. Hardcoding `/mnt/agent-home` there is a fact about one
  key, where the same string in `lib.sh` was kata inferring storage policy. Its
  `mount` prints the exact `config.local.sh` line when the key it just mounted is
  not the configured home — the deleted banner's one real warning, relocated to
  the only place entitled to say it.
- **`@bases` and `@state` on the key are now ARCHIVE space.** Bases live on the
  host disk by decision; `@state` has had no consumer since the home became a
  mount (it predates that change) and is a deletion candidate. `disk.sh status`
  says which home the sandbox is actually configured to use, so a mounted key
  that nothing is using is visible rather than inferred.
- **`require_storage` checks OWNERSHIP, not `mountpoint -q`.** The old version
  branched on the mode, which made it the last mode-dependent thing in `lib.sh`.
  The new test — `agent:agent` on the home, `$HOST_USER` on bases/shared — is
  medium-independent *and* strictly stronger: it asserts the invariant instead of
  a proxy for it, so a mounted-but-root-owned `@home` (which used to pass) now
  fails with `owned by 'root', expected 'agent'`. Same lesson as `kata status`'s
  403 versus `podman container exists`.
  The failure it exists for is unchanged and is a data-loss one: a mountpoint is
  an ordinary root-owned directory when nothing is mounted on it, so an agent-uid
  write fails loudly (fine) but a **root** write succeeds onto the root filesystem
  and vanishes under the next mount. The check is path-scoped, so
  `--home /tmp/x` demands nothing.
- **The ownership classes are the security model; only the medium changes.** Bases
  go under `/var/lib`, NEVER under the agent home, because vm.sh parses base
  qcow2s as root (`threat: base-poisoning`). "Same paths, relocated under the
  agent's home" would
  silently delete that property.
- `$MOUNT_HOME` is **755**, not 700: `git fetch $MOUNT_HOME/proj` is the return
  path and you must be able to traverse it.
- **The agent's passwd home is `/home/agent` regardless** (`usermod -d`,
  2026-08-01). It used to be `/mnt/agent-home`, a path that doesn't exist unless
  the key is in, so `sudo -u agent -i` landed in a missing directory. No script
  resolves storage via passwd — they use `$MOUNT_HOME`.
- **A plain tree loses snapshots and `kata disk rollback`** (btrfs features) and
  **removability** — not necessarily encryption at rest, which host `/` may well
  already have (`findmnt -no SOURCE /`; on this laptop it is LUKS). The old text
  here claimed otherwise and was simply wrong.
- **`config.local.sh` is sourced FIRST** by `config.sh`. Every declaration there
  **must** be `VAR="${VAR:-default}"`, so an override just wins and anything
  derived from it is derived from your value. It used to be sourced last, which
  is the *only* reason the ~40 lines of snapshot-then-re-derive pin machinery
  existed.

  **A bare `MOUNT_HOME=/mnt/agent-home` in there is a silent trap, and this repo
  taught it** — three places in `disk.sh` printed the assignment without the
  `:-`, so the file on this machine had it (fixed 2026-09-13). Nothing complains:
  normal use is identical. What breaks is every *override* — `env MOUNT_HOME=…
kata`, which README documents as supported, and any test that needs to point
  the code at a fixture. It surfaced as `tests/guards.sh` W1 failing with an
  unrelated message: the override was ignored, vm.sh ran against the real
  (perfectly valid) home, sailed past the guard under test and died at the
  stopper. **The guard was fine; the test could no longer reach it.** `unit.sh`
  C1 now asserts the contract on five variables, and W1 checks its own premise
  and *skips with the fix* rather than failing confusingly. Generalises: when a
  test fails, ask whether it still reaches the thing it names — an override that
  silently does nothing looks exactly like a broken guard.
- **Deleted with the GPU container: `grant_gpu_acls`.** disk.sh used to
  `setfacl -m u:agent:rw /dev/nvidia*` on every mount so the rootless container
  could reach the driver. The process running as uid 1001 now is qemu after its
  drop, so those ACLs were giving an escaped qemu direct ioctl access to the
  NVIDIA driver — the exact ring-0 surface VFIO removes. Don't reintroduce.
  Deleting the grant doesn't retract ACLs an older checkout already set (they
  live until the device nodes are recreated), so `net-up.sh:strip_agent_dev_acls`
  clears any `u:agent` entry off `/dev/nvidia*` + `/dev/dri/*` — as root, once
  per boot, which beats a mount hook that only fires when you use the USB.

### One agent home, mounted as `/home/agent` — `--home`, not `--workspace` (2026-08-02, renamed 2026-09-13)

**`$MOUNT_HOME` is shared over virtiofs and mounted by the guest AT
`/home/agent`.** `kata vm` needs no path argument; `--home PATH` overrides it for
one run (`--workspace` still works as an alias, for muscle memory).

Why the flag went away: it existed for the original "Claude Code but in a VM,
spawn it anywhere" idea, and that premise died. The rule the project arrived at
is that **the agent must never be given rw on a tree you own** — otherwise you
end up reviewing-then-running code it wrote, which is exactly what the git
interchange exists to prevent. `refuse_under_home` already enforced that, so the
only legal targets were agent-owned trees, of which there is exactly one per
storage mode. A flag whose only valid value is computable from config is a way
to get it wrong, not a feature.

Mounting it as the **home** rather than at `/workspace` is what makes the whole
thing pay off, because `/` is a throwaway overlay:

- `~/.claude`, `~/.cache/huggingface`, `~/.npm-global`, `~/.zsh_history` and
  every checkout now persist across sessions with **no env vars** — no `HF_HOME`,
  no `CLAUDE_CONFIG_DIR`, no `--hf` flag.
- **The `--to`-bakes-your-OAuth-creds trap is gone.** Credentials live in
  `~/.claude` on the encrypted key, so warm bases hold *system* state only
  (CUDA, apt). No more "keep a cred-free base separate from a logged-in one".
  Accepted in exchange: everything under `$MOUNT_HOME` is reachable by the agent
  and can be stolen or tampered with. That is fine for OAuth session tokens —
  bounded, revocable, fixed-cost subscription — and is the reason **only** OAuth
  creds go there. Real API keys stay on the host in `$UPSTREAM_KEYS_FILE`.
- Bases get smaller, and `npm i -g <cli>` no longer needs a re-bake to survive
  (`npmrc` puts the prefix under the home).

Traps:

- **The virtiofs tag is still `workspace`**, deliberately. Warm bases built
  before this change carry the old fstab line, and renaming the tag would make
  them mount *nothing* (`nofail`); as it is they mount it at `/workspace` —
  degraded but obvious. Fixing an old base is one line in-guest:
  `sudo sed -i 's#^workspace /workspace #workspace /home/agent #' /etc/fstab`
  then re-bake with `--to`.
- **`nofail` cuts both ways.** If the share fails, the guest boots into the
  image's empty `/home/agent` instead of stopping. Looks like "my files are
  gone"; check `mount | grep virtiofs` before believing it.
- **Nothing may be baked under `/home/agent` in the image** — it is a mountpoint
  now, so image content there is shadowed *and* silently diverges from the copy
  you actually edit. That is why the dotfiles moved to host-side seeding
  (`kata disk seed`, below) and why `user-data`'s old `chown -R /home/agent` is
  gone.
