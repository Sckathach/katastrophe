# Sessions: warm bases, detached guests, and what `--status` believes

`kata vm` hands the guest to a supervisor and returns. Everything here is about
the consequences of that — the session registry, who may bake a base, and why
the liveness check is `/proc/$pid` rather than `kill -0`.

## Warm bases: one namespace, versioned (2026-08-03)

**Every base is `$VM_BASES_DIR/<name>.qcow2` plus a `<name>.json` sidecar,
including the blank one.** `VM_BASE` — an absolute path constant pointing at
`/var/lib/agent-vm/base.qcow2` — is gone; the blank base is the one named
`$VM_BASE_NAME` (`base`), and `--from` defaults to it.

The bug that forced this, because it cost an afternoon and reads as a guest bug
the whole way: `build-base.sh` installed to `$VM_BASE` while `--from NAME`
resolved in `$VM_BASES_DIR`, and `kata bases` listed only the latter. Both
directories held a file called `base.qcow2`. So a fresh `kata build-base`
landed somewhere invisible while `kata vm --from base` kept booting a
**June** image out of `/mnt/vm-bases` — and the symptom was
"`kata-install-cuda` doesn't exist in the guest", "no fastfetch", "no `[vm]`
prompt", i.e. three separate-looking guest defects that were all one stale
image. Never add a base path outside `$VM_BASES_DIR`.

The sidecar (written by `base_meta_write` in lib.sh, read by `kata bases` and
`base_describe`) carries `version` (int, ++ on every write), `created`,
`origin` (`build`|`bake`), `parent {name, version}`, `gpu`, and a capped
`history`. Two consequences worth keeping:

- **The parent version is a snapshot taken at bake time**, so it stays true
  after the parent moves on — that difference is exactly what `kata bases`
  renders as `cuda v1 ← base v1 [STALE: base is now v2]`. A warm base built off
  a blank base you have since rebuilt is otherwise indistinguishable from a
  good one.
- **A missing sidecar is normal, never fatal.** Anything baked before this
  prints as `v?`. jq is required to *write* metadata; without it the image is
  still built and still boots. The same rule governs the newer `ca` field:
  **empty on either side is *unknown*, never *mismatch*** — refusing on unknown
  would make every pre-existing base unbootable.
- **The sidecar also carries `ca`** (2026-09-13): a short sha256 of the mitmproxy
  CA, written by `base_meta_write`, so it covers `build` and `bake` alike — and
  correctly for different reasons (a build bakes `$PROXY_CA_CERT` into the
  image's trust store; a bake freezes a guest that has been running against the
  live CA). `net-up.sh` regenerates the CA whenever `$PROXY_CA_PEM` is missing
  and only *prints* a suggestion, so without this the drift is invisible until
  every TLS request in the guest fails validation — a symptom that names the
  proxy, not the image. `kata vm` refuses a drifted base (`--force` overrides),
  `kata bases` marks it `CA DRIFT`. `ca_fingerprint` hashes
  `$PROXY_CA_CERT_PUB` first so it stays an unprivileged probe.
- **`--to` onto a STALE base is refused** (`--force` overrides). `base_stale` is
  factored out of `base_describe`, so the `[STALE]` marker and the refusal can
  never disagree. Booting a stale base read-only is fine and stays a warning;
  it's the *bake* that writes the confusion down, since `cuda v2 ← base v1`
  afterwards looks exactly as authoritative as one built on `base v3`.

Ownership: `--to` runs as root but `$VM_BASES_DIR` is you-owned 0700 in both
modes, so `save_base` chowns the qcow2 **and** the json back to `$HOST_USER`.
`build-base.sh` needs no sudo at all any more for the install step.

### Detached sessions + `kata ssh` (2026-08-03)

`kata vm --ssh` no longer owns the guest. vm.sh writes the exact qemu argv to
`$RUN_DIR/session.env` (`declare -p`, lossless) and hands the session to
**`scripts/vm-supervise.sh` under `setsid`**; the supervisor is qemu's parent
and does everything vm.sh's `cleanup()` used to: wait, bake `--to` on a clean
poweroff, kill the virtiofsds, remove the overlay/run dir/state file. vm.sh then
`exec`s `ssh.sh` and its own EXIT trap is disarmed (`HANDED_OFF`).

So: any number of `kata ssh` sessions, closing them does nothing, and you stop
the guest with `poweroff` inside or `kata vm --stop`. Attached (serial) sessions
are unchanged — qemu in the foreground, Ctrl-C takes it down, which is what a
console session should do.

Load-bearing details:

- **`$VM_STATE_FILE` is now the session registry**, not just a dashboard feed:
  it carries `pid`, `rundir`, `storage` and `attached`. "Running" means *that
  pid is alive* — a state file whose pid is gone is a leftover and is cleared,
  never a reason to refuse the next launch. One session at a time is enforced
  from it (two guests would race for `$VM_IP`, the shares, and the card).
- **Liveness is `/proc/$pid`, never `kill -0`** (`pid_alive` in lib.sh, added
  2026-08-03 after it broke the first real session). qemu runs as the agent uid
  (`-run-with user=agent`), so `kill(2)` from *your* uid returns **EPERM** and
  the process reads as dead. The result was a state file that answered
  differently depending on who asked: `kata vm --ssh` launched the guest, then
  its own `exec ssh.sh` — which drops back to `$SUDO_USER` — printed "no session
  running", while the next `kata vm` (root, so `kill -0` works) refused to start
  a second one. Nothing was wrong with the VM. `session_alive` also requires the
  rundir to still exist, as the pid-reuse guard.
- **`--status` reports the SESSION, never this invocation's flags.** A session's
  home is fixed at launch, and an explicit `--home` is still a per-run choice, so
  reading it back from the state file is the rule. (It used to re-resolve a whole
  storage *mode* that way, because printing `$VM_BASES_DIR` from the current flags
  told you a `--usb` session would bake into `/var/lib/agent-vm/bases`. The mode is
  gone; the believe-the-session rule survives it.) Related trap fixed 2026-09-13:
  `state_field` used `jq '.[$k] // empty'`, and jq's `//` fires on `false` as well
  as `null`, so `gpu: false` printed as `gpu=` — a present-and-false field reading
  as *unknown*. Test for `null` explicitly.
- **`state_field`, `listens` and `proxy_state` live in `lib.sh`, once.** They were
  duplicated between `kata` and `vm.sh`, and the copies diverged the moment one
  was fixed: for a few commits `kata vm --status` said `gpu=false` while `kata
status` still said `gpu=`. Same file, two readers, two answers. **A probe
  duplicated across callers is a probe that will eventually disagree with itself**
  — if two commands report on the same state, they must share the reader.
- **virtiofsd is started with `SIGHUP` ignored** (`trap '' HUP` across the fork,
  `nohup`-style — an ignored disposition survives fork+exec). Without it,
  closing the launching terminal kills the virtiofsds and therefore the guest's
  *home*, while the guest keeps running. vm.sh also traps HUP itself now: a bash
  killed by an untrapped signal does **not** run its EXIT trap, which is why
  killed terminals left state files, run dirs and overlays behind.
- **`--stop` presses the ACPI power button over an HMP unix socket**
  (`-monitor unix:…`), not `ssh … poweroff`: no guest password, and the guest
  shuts down properly so qemu exits 0 and the `--to` bake stays eligible.
  Attached sessions have no monitor socket (stdio holds it) and record vm.sh's
  pid rather than qemu's, so `--stop` refuses them by name instead of
  pretending.
- **`--force` writes a `no-bake` marker into the run dir, and that — not the
  exit status — is what stops the bake.** qemu handles SIGTERM as a shutdown
  request and **exits 0**, so the supervisor's "rc == 0 means the guest powered
  off cleanly" test cannot tell a forced stop from a real poweroff. Without the
  marker, `--stop --force` (which prints "will NOT bake a base") would have
  flattened a half-provisioned session over the warm base it was replacing —
  and a `--to cuda` bake silently overwrites 15G+ of downloads. `--force` also
  escalates to SIGKILL after 5s. Relatedly, the launch banner now names what a
  `--to` would replace (`REPLACES the existing cuda v1 (16G)`); re-baking a name
  is the normal workflow, so this stays a warning and not a guard.
- **`--status` is the one `kata vm` verb that doesn't sudo** (`privilege()`
  inspects the args). Asking for a password to answer "is the VM up" trains you
  to type it.
- `ssh.sh` re-execs itself as `$SUDO_USER` with `-H` when it starts as root
  (vm.sh execs it from a sudo'd context): otherwise it would use root's `~/.ssh`
  while a plain `kata ssh` used yours.
- `kata disk seed` also installs your ssh **public** key into
  `$MOUNT_HOME/.ssh/authorized_keys` when you have one, so N terminals aren't N
  password prompts. Safe direction: a public key grants login *to* the sandbox.
  The agent owns that file and can rewrite it — all that buys it is choosing who
  may ssh into the box it already controls. Do **not** add `ssh -A`.

### `kata status` — and why it needs no sudo (2026-09-08)

This section used to be "`kata dash` and the sudo timestamp", ~60 lines about a
read-only TUI that could not read anything. The dashboard shelled out with
`sudo -n` for two nft tables, `podman ps` and two `podman logs -f` tails; `sudo
-n` never prompts, so it worked only with a cached sudo timestamp, and **this
host caches none** (hardened sudoers, `timestamp_timeout=0`-style). Every
privileged row therefore rendered red on a perfectly healthy sandbox. The
documented fixes were all bad: a NOPASSWD drop-in (installed, verified, removed
the same day), or a long-lived root helper.

The resolution was to notice the checks were the wrong shape. **A functional
check proves more than a privileged read, and needs no privilege:**

```sh
curl -x http://10.201.0.1:8080 http://kata-status.invalid/     # must be 403
```

That one request proves the proxy process is alive *and* that the allowlist addon
is loaded — from any uid — and it is strictly better than what the privileged
reads could see: during the IPv6 episode `nft list` and `podman ps` were both
green while the proxy answered nothing at all.

**What it does NOT prove, corrected 2026-09-13** (this text used to claim the
bridge and the `agent_vm` accept): the request is issued **from the host to a
local address**, so it never arrives over `virbr-agent` and never traverses
`agent_vm input`. Guest-side egress is only really proven from inside a guest —
that is what `audit-egress.sh` is for. An over-claiming health check is worse
than a missing one, because it makes you stop looking. Hence `vm.sh`'s launch
preflight runs **three** checks (link, `agent_vm` table, `proxy_state`) and none
of them subsumes another.

**In `vm.sh` an unexpected HTTP code is a refusal, not a warning** (`status`
still only warns — it reports, it doesn't gate). Anything other than 403 means
something is listening on `$PROXY_PORT` that is not our allowlist, so the guest
would boot with **unfiltered egress** while every structural check stayed green.

Everything else `status` reports comes from `ss -lnt`, `ip`,
`df`, `stat` and the world-readable `$VM_STATE_FILE`. Switching the searxng row
(and litellm's, while it existed) from `podman container exists` to `listens()`
dropped the last privileged read.

What survives: **`agent_isolate` is the one thing no unprivileged check can
prove** — exercising a `skuid=$AGENT_UID` drop means becoming that uid, which
needs root. `status` tries `sudo -n`, and when sudo declines it prints
`unknown (needs sudo)` rather than a red row, because "I could not look" is not
"it is broken". `kata doctor` is the one allowed to prompt, and it distinguishes
the two cases properly: only a `sudo:`-prefixed stderr is a sudo failure; nft's
own "No such file or directory" means the table is genuinely absent. Getting
that backwards reports a healthy host as broken, which is the bug the old
`sudo -n true` probe had.

The live log streams the dashboard also carried are `sudo podman logs -f
agent-proxy` in a pane. Better than the custom TUI, and nothing to maintain.
Note the `sudo`: the proxy is a rootful container, so that stream always needed
root. The dashboard's mistake was not needing root — it was demanding root
**non-interactively** (`sudo -n`) from a program that could not prompt.

### The guest root disk is NOT storage on the key (`VM_DISK_SIZE`)

Still worth stating, because it reads backwards from inside the guest where both
look like ordinary directories. Two unrelated things:

- `/`, `/usr`, `/var` are the qcow2 **session overlay** — a virtual block device
  sitting in `$VM_IMAGES_DIR` on the **host root filesystem**, capped at
  `VM_DISK_SIZE`, and deleted at poweroff unless `--to` bakes it.
- `/home/agent`, `/mnt/ro_N`, `/mnt/rw_N` are **virtiofs**, a pass-through to a
  host directory. No size of their own, no copy: writing there *is* writing to
  the key, with the full 900G behind it.

So raising `VM_DISK_SIZE` buys nothing but a bigger hole in host `/`, and since
the home is now a mount there is very little left that would want it — 40G holds
Ubuntu + CUDA + apt scratch with room to spare. Two follow-ons: a bumped
`VM_DISK_SIZE` does **not** grow an existing warm base's partition (sessions run
with cloud-init disabled ⇒ no growpart — you need in-guest `growpart` +
`resize2fs` then a re-bake), and the guest's `agent` user takes `AGENT_UID` from
the same config, which is what makes virtiofs writes land on the key owned by
the host's `agent` rather than as a stranger's uid.

`VM_MEM`/`VM_SMP` (32G / 10 here) moved out of `vm.sh` into `config.sh`
2026-08-02, so `--mem`/`--smp` are overrides rather than something you type every
run. Under `--gpu` that memory is genuinely committed — `prealloc=on` plus
`RLIMIT_MEMLOCK` = `VM_MEM`+1G — not lazily faulted.
