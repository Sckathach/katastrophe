# Rejected and deleted, with the reasoning

The ADR graveyard. Everything here was either **built and removed** or
**proposed and declined**, with the argument that settled it. `CLAUDE.md` keeps
saying *"don't re-add this without re-reading why"* — this is that file.

A superseded decision is **annotated, never edited**. If you reverse one, add the
new argument underneath rather than deleting the old one; the old one is what
tells the next person whether the reversal considered it.

---

## Built, then deleted

### The appliance (rootless SLIRP VM with an in-guest gate) — 2026-08-01

Its value was "no host setup, shareable, demoable", and the repo went private, so
that was worth roughly zero. It was also the **weakest thing on offer**: no
host-kernel gate, and TLS *passthrough*, so a body-inspecting probe structurally
could not work there. Keeping a weaker option around mostly invites its use.

If the "works with no host setup" property is ever wanted again, the cheap way is
a degraded `--slirp` mode inside `vm.sh` — **not** a second image, a second
addon and a second build path.

### The GPU container (rootless podman + CDI) — 2026-08-01

Replaced by VFIO passthrough. Its premise — "passing a laptop GPU into a VM needs
a spare GPU" — was simply false on this machine.

The delete was a real tightening, not a wash: the container reached the driver
through `setfacl -m u:agent:rw /dev/nvidia*`, and the process running as uid 1001
*now* is qemu after its drop. Those ACLs were handing an escaped qemu direct
ioctl access to the NVIDIA driver — exactly the ring-0 surface VFIO removes.
`net-up.sh` strips any leftover `u:agent` entry once per boot.

### The whole `nixos/` tree — 2026-08-01

With the appliance gone and the VM on Ubuntu, Nix had no consumer left. The flake
was genuinely tidier for a blank shell image, but the workload is ML — binary
wheels, CUDA, vendored `.so`s — which is NixOS's worst case, and the escape hatch
(`uv`) broke the reproducibility that was the reason to use Nix at all. The
agents that live in this VM know `apt`, not `configuration.nix`.

### The Rust CLI (`cli/`, ~2,250 lines) — 2026-09-08

Its jobs were arg parsing, a privilege table, exec-ing a bash script, and three
read-only reports — and `config.rs` shelled out to bash to `source config.sh`,
which was the tell that the whole thing wanted to be bash. Net −2,533 lines.

What actually forced it: Rust's `find_root()` walked upward from `$PWD` and from
`~/.cargo/bin`, so **moving the checkout broke the binary**. `kata` resolves
`REPO_ROOT` through `realpath "$0"`, which cannot recur.

### `kata dash` (1,062 lines of ratatui) — 2026-09-08

A read-only TUI that could not read anything. It shelled out with `sudo -n` for
two nft tables and `podman ps`; `sudo -n` never prompts, and this host caches no
sudo timestamp, so every privileged row rendered red on a perfectly healthy
sandbox. Both documented fixes were worse than the problem (a NOPASSWD drop-in —
installed, verified, removed the same day; or a long-lived root helper).

The resolution was to notice the **checks were the wrong shape**. Its two jobs
are now `sudo podman logs -f agent-proxy` in a pane (the proxy is a rootful
container — its log has always needed root; what it never needed was a program
asking for that root *non-interactively*), and `kata status`, which needs no
privilege at all. See [sessions.md](sessions.md), "`kata status` — and why it
needs no sudo".

### litellm — 2026-09-11

It was doing one thing for us: holding real API keys so the guest never saw them.
`proxy/mitmproxy/addon.py` now swaps the sentinel for the real key on the way
upstream — no second service, no second port, no model-name mapping, and the
guest spends a key it can never read.

What we gave up is **cross-provider request translation**. If that is ever
wanted, litellm comes back as an opt-in, not as the default path.

### The probe — parked 2026-09-11 (recoverable with `git show`)

It was a keyword-blocklist smoke test wearing the shape of a real
interpretability check, and the honest reading is that the sandbox holds while
the guardrail did nothing. Better to have no guardrail than a decorative one.

Its one real finding survives as a design constraint for whenever it comes back:
**streamed responses were never post-probed.** Only `async_post_call_success_hook`
was implemented, which fires for non-streaming responses; chat clients stream, so
model *output* went unchecked and a harmful answer only tripped on the next turn,
once it was history. A revived probe must probe-as-you-go on the streaming
iterator — buffering the whole stream to inspect it defeats streaming UX.

### The `--usb` storage mode (`KATA_STORAGE`) — 2026-09-13

**A mode bundles two independent questions into one boolean, and then the two
halves of one workflow can answer it differently with nothing reporting the
disagreement.** `kata disk mount` followed by a `kata vm` without `--usb` used a
*different home*. `kata --usb build-base` wrote a base that `kata vm --from base`
could not see — and that one presented as three unrelated guest defects for an
afternoon.

The previous attempt at a fix was a louder banner announcing which tree had won.
The actual fix is **having no second candidate to be wrong about**: one
`$MOUNT_HOME` constant, named once per machine, overridable per run with
`--home PATH`.

Do not make the USB special in `kata` again. It is a mount, nothing more.

### The MkDocs site (`docs/`, 20+ pages) — 2026-09-13

Stale since the home-as-a-mount rebuild six weeks earlier: it documented
`--workspace DIR` as required, `/workspace` as the guest mount point, `--no-usb`
as the storage flag, and knew nothing about detached sessions, `kata ssh`,
versioned bases or profiles. The README carried a paragraph apologising for it,
which is the clearest possible signal.

Two parts had content that is not derivable from the code and survived:
`knowledge/threat-model.md` and `knowledge/related-work.md`. One part had a
*better* destination than prose — the ~40 numbered security invariants became
`tests/`, under the rule **an invariant with no runnable check is a claim**.

---

## Proposed and declined

### A compose stack for the services

> *"can't we do smt like: we have a docker compose with the services:
> litellm/gitea (or lighter)/websearch/whatever, and open it on one side for me /
> internet, on the other side for the agent?"*

Right instinct, wrong lever. **Compose makes declaring services nicer; it does
not make you have fewer services, and fewer services is the bigger win.** After
litellm went there are two containers, and compose for two buys ~80 lines of
`podman run`.

It also costs a networking wrinkle that is easy to miss: **published ports get
DNAT'd in prerouting, so traffic lands in the `forward` hook, not `input`.**
Every `agent_vm input` accept stops matching, and podman installs its own nft
rules alongside ours.

**The one thing worth taking from the idea** is that searxng should not have host
netns (`threat: searxng-host-netns`). One container on its own podman network,
published on the bridge, with the accept moved to a forward rule, is a real
tightening — as a targeted fix, not a stack rewrite. Not scheduled.

### Gitea

Ergonomics, not simplification: a forge + a DB + persistent state + auth config,
and you would *still* want the ingress/egress split for the append-only review
trail. What it buys is browsing diffs in a web UI, which is `tig` locally. The
`git daemon` + two bare repos with `daemon.receivepack` on exactly one of them is
one of the best things in the repo — don't trade it.

### A justfile instead of the `kata` dispatcher

1. **The privilege table is logic, not a recipe.** `privilege()` classifies each
   subcommand Root/User/Any, and the `User` arm *refuses* to run as root — which
   is what stops `sudo kata build-base` leaving a root-owned `guest/.cache`. just
   cannot express that; you would copy `sudo` into every recipe.
2. **`kata vm --status` kills it outright**: `privilege()` inspects the *args*, so
   `kata vm` sudos and `kata vm --status` does not. A fixed recipe would need two
   recipes over one script, and the two surfaces would drift.
3. just is a new host dependency, immediately after deleting 2,250 lines of Rust
   whose job was arg parsing plus a privilege table.

**The observation behind the question was right**, though: most of `kata` is
shared probes plus three read-only reports. Moving `status`/`bases`/`doctor` into
`scripts/` would leave a pure dispatcher — same goal, no new dependency.

### incus / libvirt instead of raw qemu — DEFERRED, libvirt is the target

Not now (*"we'll do that later"*), but the analysis, so it is not re-derived.

**libvirt beats incus for one specific reason**: a domain can carry
`<seclabel type='static' model='dac' relabel='no'><label>agent:agent</label></seclabel>`,
so qemu runs as the agent user and `threat: qemu-uid-drop` is preserved. Incus
runs qemu under its root daemon, trading that for AppArmor confinement.
**Neither claim is verified. Verify before committing** — it is the crux, and the
check is cheap: `ps -o user= -p $(pgrep -f qemu)` against a running incus VM.

What libvirt would delete (~1,600 lines): virtiofsd spawning + the socket wait +
the HUP-ignore trick, `vm-supervise.sh` + the `session.env` handoff, the HMP
monitor socket, the state file as a session registry (**the whole "`kill -0` is
EPERM" bug class stops existing**), VFIO arg assembly, and the provisioning boot.
The nft model would be 100% unchanged.

Be honest that this is **your-code for their-code, not less total complexity**.
The argument for it is that their code is maintained and portable and ours has to
be re-debugged on every new machine.

Also considered: **systemd-vmspawn** (the most interesting *small* option — no
daemon, `--bind` for virtiofs, lifecycle as systemd units so `systemctl status`
*is* the dashboard row; but young, and VFIO is not first-class),
**cloud-hypervisor** (has VFIO, but you would write the same launcher),
**firecracker** (no PCI passthrough), **quickemu / Vagrant / crun-vm** (wrong
shape, or a layer over libvirt anyway).

### The USB as a security property

Four candidate reasons, only one survives, and it is medium-independent:

1. **LUKS at rest** — only does real work if the laptop root is not encrypted.
   It is (LUKS on `/`), so the key adds nothing.
2. **Physically removable** — real, but the sandbox is not running while it is
   unplugged, so (1) already covers theft-while-off.
3. **btrfs snapshots + rollback** — real, and entirely reproducible with a
   subvolume on the internal disk.
4. **`@bases`/`@snapshots` outside agent write reach** — pure chown/mode.
   Identical anywhere. **This is the actual security model.**

So the key is a convenience and a bulk store, `kata` never learns what a USB is,
and `disk.sh` is the only file in the repo that knows what LUKS or btrfs are.

---

## Never do these

Short list, each of which was a real mistake once.

- **`--security-opt=apparmor=unconfined` on the containers.** A wrong diagnosis;
  the real failure was `--cap-drop=ALL` versus the image's root entrypoint.
- **`allow_unsafe_interrupts=1` to make VFIO work.** It lets the guest inject
  MSIs at the host, which defeats the entire project.
- **`sudo -n true` as a probe for "can I sudo".** Wrong twice now. Only a
  `sudo:`-prefixed stderr is a sudo failure; the command's own error means the
  thing you asked about is genuinely absent. Backwards, it reports a healthy host
  as broken.
- **`podman container exists` / `nft list` as a health check.** Both stayed green
  through the IPv6 episode while the proxy answered nothing at all. Check
  function, not structure.
- **`sudo -E` to fix a stripped environment.** It depends on the host's sudoers
  `setenv` policy, so it makes the bug machine-specific instead of fixing it.
- **`ssh -A` into the guest.** Agent forwarding hands the sandbox your keys.
- **Un-pinning `github.com`** without deciding you want the agent to push.
- **Removing `refuse_under_home`** to make a test pass. Fix the test.
