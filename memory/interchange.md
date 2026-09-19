# Sharing work with the agent

Projects, the git daemon, the HuggingFace cache, and the foot-gun guard on host
paths. The governing rule — `threat: git-interchange` — is that trust flows one
way: you → sandbox freely, sandbox → you as reviewable data only.

## Trust flows one way

The governing rule: **trust flows one way.** Code/data may flow trusted →
sandbox freely (even read-only-shared); the reverse (anything the agent wrote)
must never be _executed or deserialized_ as the host user. A model pickle, a
`trust_remote_code=True` repo, even a `pip install -e .` of an agent-authored
tree all run arbitrary code as whoever loads them. So:

- **`user → agent`**: fine. You feed your own code/models to the sandbox.
- **`agent → user`**: inspect/read only. The single sanctioned return
  channel is `git fetch` — git objects are data, not executed. Never carry an
  agent-produced artifact back by running it.

### Project round-trip (git daemon on the bridge)

**Wrapped by `kata project` (repos) + `kata git` (daemon).** The one-command path:

```bash
kata git up                            # git daemon on git://$HOST_IP:$GIT_PORT, runs as YOU
kata project add  <host-repo> [name]   # both bare repos in shared-storage/src/, wire remotes
kata project push <name>               # (in your checkout) push your branch → ingress
kata project pull <name>               # (in your checkout) fetch the sandbox's pushes
                                       # into refs/remotes/agent/* — review, never run
kata project list / kata git status
```

Topology (2026-07-28, replaces the cp/bundle dance): **two you-owned bare repos**
in `shared-storage/src/` — `<name>.git` (ingress) and `<name>-agent.git`
(egress) — served by `git daemon --base-path=$SHARED_SRC_DIR`. In the guest it's
one remote with a split url/pushurl, so `git pull` reads your branches and
`git push` writes the egress repo.

Things that are load-bearing and easy to break:

- **The r/w split is git's own per-repo service config, not a hook.** Only the
  egress repo sets `daemon.receivepack=true`; `git daemon` disables receive-pack
  globally and allows per-repo override by default. A push to `<name>.git` dies
  with `service not enabled` **before** any object is written. Don't "simplify"
  this into one repo with a pre-receive hook.
- **The `-agent` suffix is REFUSED on your project name, not required** — a
  recurring misreading of the README's "only the `-agent` repo accepts pushes",
  which describes the egress bare repo. `project.sh` rejects `*-agent` / `*.git`
  as a project name because it needs `<name>-agent.git` for the egress half.
  Any other name is fine, and the source repo may live in your home (`project
add` clones as you; `refuse_under_home` guards only `--workspace`/`--rw`).
- **The egress repo is append-only** (`receive.denyDeletes` +
  `receive.denyNonFastForwards`, added 2026-08-02). This is *not* branch
  protection — your branches were never reachable, since the agent pushes into a
  separate repo and `project pull` only writes `refs/remotes/agent/*`. It
  protects the **review trail**: without it the agent can rewrite or drop history
  you already fetched and read, so a second `project pull` disagrees with the
  first for no visible reason. Repos created before that date need the two
  `git -C <name>-agent.git config …` lines backfilled by hand.
- **Never pass `--export-all`.** Repos opt in via `git-daemon-export-ok`, so a
  stray repo under `$SHARED_SRC_DIR` isn't exposed.
- **The daemon runs as you, not root** — it binds an unprivileged port and must
  write repos you own. `kata git` therefore never wraps in sudo. Consequence:
  the pidfile is under *your* `XDG_RUNTIME_DIR`, which root-side scripts
  (net-down.sh) can't see — they check the port binding instead.
- **The egress repo is a bare clone of the ingress, not `git init --bare`.**
  Shared history ⇒ the agent's first push is a delta; from an empty repo it
  would be a full re-upload that `receive.maxInputSize` (256M) may reject.
  Not `--shared`/alternates either: that couples the two repos' gc lifetimes.
- The agent worktree under `$AGENT_WORK_DIR` is **optional** — it only helped
  the filesystem-sharing GPU container, which no longer exists. `project.sh`
  skips it with a notice when there's no agent user or `$MOUNT_HOME`; the VM
  clones over `git://` and needs none of it.

Threat write-up: `threat: git-interchange`. G4 is checked by `tests/host.sh`;
G1–G3, G5 and G6 need a guest and live in `tests/MANUAL.md`.

The rest of this section is the _mechanism_ (and the manual fallback when you
want to drive it by hand, or when the daemon isn't up).

`/mnt/agent-home` (`$MOUNT_HOME`) is agent-owned, mode 755: you can _read_ it,
only `agent` can _write_ it. So the natural grain is to do the agent-side work
**as the agent uid**, and reconcile back via git.

**Ingress — `agent` can't reach your `0700` home, so you can't `sudo -u agent
git clone /home/user/...` (agent can't traverse the path → "does not
exist"; same root cause as the `statfs` foot-gun).** The data must pass through
a channel agent can reach. Two that work:

```bash
# (a) simplest — root CAN read your 0700 home; copy in, hand to agent:
sudo cp -r /home/user/desktop/proj /mnt/agent-home/proj
sudo chown -R agent:agent /mnt/agent-home/proj

# (b) git-all-the-way — bundle through /tmp (1777, so agent can traverse it):
git -C /home/user/desktop/proj bundle create /tmp/proj.bundle --all
sudo -u agent git clone /tmp/proj.bundle /mnt/agent-home/proj && rm /tmp/proj.bundle
```

Copying files (not just git objects) is fine _here_ — ingress is the trusted →
sandbox direction. (`sudo -u agent git clone <url>` also works since it's
network, but agent egress is proxy-only, so the host must be on the allowlist.)

```bash
sudo -u agent -i                       # login shell as agent; work alongside it
cd /mnt/agent-home/proj                # `kata vm` mounts this tree as the guest's home

# egress — the ONLY safe way back into your real repo (git objects, not files).
# You run this as user; you CAN read /mnt/agent-home (755):
cd /home/user/desktop/proj
git fetch /mnt/agent-home/proj '+refs/heads/*:refs/remotes/agent/*'
```

When you are `agent`, you have **no boundary** from the agent's untrusted code
(same uid) — fine, as long as the return path is git-fetch + diff review, never
"run the thing it produced".

### HuggingFace cache

A shared **writable** cache that the host also loads from is the pickle hole —
the agent could overwrite a model with a poisoned pickle that executes as
`user` on next load. Two safe shapes instead:

- **The default, and what to reach for first: the agent's own cache**, at
  `$MOUNT_HOME/.cache/huggingface` — which is simply `~/.cache/huggingface`
  inside the guest now that the home is a mount, so it needs no `HF_HOME`, no
  flag, and no setup, and it survives sessions. Malicious pickles there execute
  as `agent` inside the sandbox → contained. **Never load from it as `user`.**
  Each storage mode has its own; duplicating a few GB beats engineering a
  shared one.
- **A shared cache, read-only into the sandbox, populated only by you** — worth
  it only when you already have the weights and don't want a second copy. Put
  it _outside_ your 0700 home (so the agent uid can traverse it), owned by you,
  world-readable:
  ```bash
  sudo install -d -o user -g user -m 755 /srv/hf
  export HF_HOME=/srv/hf            # your personal downloads land here too
  kata vm --ro /srv/hf              # → mounts at /mnt/ro_1 in the guest
  ```
  Read-only means the agent can't poison it; the pickle risk is then exactly
  your normal risk (you chose to download those models).

`.safetensors` weights carry no code and are safe to share even writably — but
`config.json`, tokenizers, and `trust_remote_code` `.py` still execute, and
enforcing "safetensors-only" across a cache is brittle, so don't lean on it to
make a writable shared cache safe.

### Foot-gun guard on host paths

`config.sh` exports `refuse_under_home <path> [flag]`; sandbox scripts call it
for the workspace (rw) **and** every `--rw` mount. It rejects a path under
`FORBIDDEN_WORKSPACE_PREFIX` (your home) early and loud, instead of the opaque
`statfs ...: permission denied` rootless podman throws when the agent uid can't
traverse a 0700 home. Bypass with `FORBIDDEN_WORKSPACE_PREFIX=`.

**`--ro` is exempt, deliberately:** virtiofsd runs as root and reads your home fine,
the guest sees only the mounted subtree, and an escape lands as the agent uid
which `agent_isolate` already fences — so read-only ingress of a real project is
the intended workflow, not a foot-gun. `--workspace` and `--rw` stay guarded;
those are writes into your tree.

Since 2026-08-02 the workspace check is near-vacuous — the default is
`$MOUNT_HOME`, which can't be under your home. Keep it anyway: it is the only
thing standing behind an explicit `--workspace`, which is now the *only* way to
point the agent at a tree you own.
