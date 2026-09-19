# Threat model

What this sandbox defends against, what it accepts, and where the load-bearing
controls are. This is the one document in the repo that is **not derivable from
the code** — everything else worth knowing lives in script comments, `CLAUDE.md`
or `tests/`.

Each threat has a **slug**, and code comments cite it as `(threat: base-poisoning)`.
Slugs, not numbers, because a citation should tell you what it is without a
lookup. Grep for a slug to find every place that depends on it.

Proof, not prose: an invariant with no runnable check is a claim. See
[knowledge/testing.md](testing.md) — `kata test` runs what can be run,
`tests/MANUAL.md` is the short list of what genuinely cannot be.

Legend: **L** likelihood · **I** impact · **S** status
(`accepted`, `mitigated`, `partial`, `open`).

## The shape in one table

| Outer wall | qemu runs as | a *runtime escape* lands as | egress gate |
| --- | --- | --- | --- |
| KVM + IOMMU | the agent uid | **the agent uid**, not root | host nft, survives guest compromise |

Guest-root inside the VM is **not** an escape — it stays behind KVM and touches
nothing on the host. The middle column is where a *real* hypervisor escape puts
the attacker.

Two weaker runtimes were deleted in 2026-08: a rootless "appliance" (SLIRP + an
in-guest gate, defeatable by guest root) and a rootless-podman GPU container
(user namespaces — the weakest wall on offer). Removing them removed the two
weakest boundaries in the project. See `knowledge/rejected.md`.

## The 2026-08 escape report

[vm-escape-2026-08.md](vm-escape-2026-08.md) is kept verbatim in this directory:
an agent escaping qemu/KVM on a developer laptop, three times, in about twelve
hours. It is the first public account of the exact boundary this project is built
on failing, and it is the reason several flags in `vm.sh` exist. Our reading:

| his escape | us |
| --- | --- |
| host kernel CVE (Januscape) | **applies.** He ran Debian 12 oldstable with `mitigations=off`. We run `linux-hardened`, `pti=on`, full LSM stack, `audit=1`, current qemu, `vmscape` mitigated. His strongest recommendation — "a distribution with rapid updates is now a requirement" — we satisfy. |
| **libslirp** (CVE-2026-9539 + an unmarked fix) | **structurally absent.** See `no-slirp` below. |
| the 0-day chain | **partially.** VAPIC/SMRAM → `qemu-device-surface`. KVM `paging64_invlpg()` → **applies, irreducible**, this is `kernel-cve`. The libslirp heap-spray that located the hijacked callback → absent. The CUPS pivot → `agent_vm` accepts only the sandbox ports, so host :631 was never reachable. |

**What this changes in the model.** Not the shape — the emphasis. `kernel-cve`
was always `accepted`; it is now the **load-bearing** acceptance, and everything
else here is defence in depth around a hole we cannot close. That is why host
compromise moved from *out of scope* to *assumed and bounded* (see the last
section), and why the monitoring work in `probes.md` starts at enforcement rather
than at detection.

**What it does not change:** his recommended fix is Firecracker, which has no PCI
bus and therefore no VFIO. A project built around a passed-through GPU cannot
take that advice. The candidate that fits is Cloud Hypervisor — same minimal
device model, but it supports VFIO and virtio-fs. Filed, not done.

## no-slirp — the escape we do not have

- **L/I/S**: n/a / n/a / **do not regress**
- `vm.sh` attaches the guest with `-netdev bridge` (a tap device on
  `$BRIDGE`). **In a session, libslirp is not linked into the process**, so his
  second escape — and the heap-grooming primitive his third one relied on — have
  no target.
- **The exception, stated rather than glossed: `build-base.sh` uses `-nic user`,
  i.e. SLIRP.** It has to — it runs unprivileged (`kata build-base` refuses
  root), and a tap on the bridge needs root. The risk is genuinely different
  there: no agent is in the loop, the workload is Ubuntu's cloud image running
  *our* cloud-init, and the process runs as you rather than as uid 1001. But it
  *is* network-facing (apt, nodesource), so "libslirp is absent" is a claim about
  the session path only. Do not let it drift into a claim about the project.
- This was not foresight about libslirp. The runtime that used userspace
  networking (the rootless appliance) was deleted in 2026-08 for unrelated
  reasons, as the weakest boundary on offer. It paid off anyway.
- **`-netdev user` must never come back.** It is the single easiest fix for any
  networking problem — no bridge, no root, no `qemu-bridge-helper` — and taking it
  would hand back an entire published escape chain. If the bridge is broken, fix
  the bridge.

## qemu-device-surface — every emulated device is reachable

- **L/I/S**: med / critical / mitigated (2026-09-14)
- Guest userspace talks to every device qemu instantiates, and qemu instantiates
  a great many by default. Measured with `info qtree`: **26 device types before,
  14 after**.
- Two removals are not generic hygiene; they come from named bugs in the report:
  - **VGA.** q35 creates a stdvga with 16MB of vgamem regardless of any display
    backend. `-display none`, which we already passed, removes the *backend* and
    **not the device** — verified in `qtree`, and this is exactly the footnote in
    his bug table: the QEMU panning-buffer overflow went unused only because no
    display listener reached the renderer. `-nodefaults -vga none` removes the
    device. Costs nothing; the console is serial.
  - **SMM.** His chain opened with "VAPIC's unchecked ROM alias could overlap
    locked SMRAM". `kvmvapic` has no off switch, but `smm=off` means there is no
    SMRAM to overlap and no SMM to execute in. Safe here because we boot SeaBIOS
    with no pflash and no secure boot. **This is the flag most likely to break a
    boot** after a qemu or image change — bisect from it first.
- The rest is provably unused: virtio-blk boot (`sata=off`, no default `ide-cd`),
  no graphical input (`i8042=off`), no USB, no parallel port, `smbus=off`,
  kvm-clock (`hpet=off`), `vmport=off`.
- **Do not drop `-nodefaults` to make a device appear.** Add that device
  explicitly instead, so the addition is visible in review.
- Checked by: `tests/unit.sh` (the flags are present), `tests/MANUAL.md` (the
  guest boots and the qtree is what we claim).

## Trust boundaries

1. **The agent uid (1001).** Kernel DAC, the persistent `agent_isolate` skuid
   chain and the storage ownership split all hang on this uid. Anything crossing
   uid 1001 → another uid on the host (root included) breaches the sandbox.
2. **The host bridge.** The guest lives behind KVM; the bridge is its only
   host-exposed surface, and `agent_vm` filters everything off it.
3. **The IOMMU, under `--gpu`.** A passed-through GPU can DMA, and the IOMMU is
   what confines that DMA to guest memory. Interrupt remapping is the half that
   protects *host* integrity.
4. **Host root / the host user.** Out of scope — both can disable every control.

---

## qemu-uid-drop — an escape lands soft

- **L/I/S**: n/a / n/a / **do not remove**
- `vm.sh` launches qemu with `-run-with user=agent`, so the vCPU thread — the
  thing a hypervisor escape actually rides — is uid 1001 by the time the guest
  executes its first instruction. The escape therefore lands *inside*
  `agent-isolate`'s jurisdiction instead of as root.
- This is why the whole model can hang off one uid. Everything below that says
  "an escaped qemu" is relying on it.
- Checked by: `tests/MANUAL.md` (needs a running session).

## agent-isolate — the host-kernel fail-safe

- **L/I/S**: n/a / n/a / **do not remove**
- A persistent nft table in `/etc/nftables.d/`, loaded by its **own** systemd
  unit, dropping `skuid 1001 →` RFC1918 + CGNAT (tailnet) + link-local +
  multicast. It is what isolates the agent uid from your LAN, your VPN and every
  other host you can reach.
- It is the only control that survives a compromise of *everything else here* —
  the guest, qemu, the proxy, the bridge rules. `net-up.sh` refuses to start
  without it.
- A dedicated unit rather than `nftables.service`, so it cannot collide with
  whatever else filters on the host: ufw/firewalld own the `ip`/`ip6` families,
  this is `inet` and every rule is skuid-qualified.
- **It carries no exceptions since 2026-08.** The per-port holes existed only for
  the rootless GPU container, whose host sockets carried skuid 1001. The guest's
  traffic arrives over the bridge carrying no skuid at all, and qemu itself opens
  no TCP — so an escaped qemu can reach neither the proxy, nor the git daemon,
  nor searxng. Do not "restore" them.

## host-spoof — the gate must judge the destination

- **L/I/S**: **was high** / critical / mitigated (2026-09-13)
- The allowlist ran on mitmproxy's `request.pretty_host`, which prefers the
  client's `Host:` header. So the gate audited a name the client chose while
  forwarding to a destination it never looked at, and **one curl flag reached any
  address on the machine** — host loopback, the LAN, the tailnet. `agent_isolate`
  cannot help: that socket belongs to mitmproxy as uid 1000, not to the guest.
- Worse than the hole: `podman logs` printed `ALLOW pypi.org GET /exfil-proof`
  for traffic delivered to `127.0.0.1`. A monitor reading attacker-controlled
  data reports the attacker's story, confidently.
- **Mitigation**: `Egress._gate` judges `request.host` (the request line / the
  CONNECT authority) and additionally **refuses any mismatch** with the `Host:`
  header — shared origins (`*.run.app`, HF Spaces, Pages, any CDN) route on the
  header, so an allowlisted destination plus a foreign `Host` still reaches
  attacker content. Nothing legitimate ever sends a mismatch: the guest has no
  resolver and reaches everything by name through this proxy.
- Checked by: `tests/gate.sh` D1–D3 (as deployed, incl. non-arrival at a
  loopback listener) and `proxy/mitmproxy/test_addon.py`.

## allowlist-drift — the list only ever grows

- **L/I/S**: med / med / partial
- Every host on the allowlist is a potential exfil channel. PyPI's publish
  endpoint, HF model uploads and GitHub gists are exfil *by design*.
- **Mitigation (composition)**: hosts live in groups composed into profiles
  (`swe` / `research` / `local`), so a SWE session does not carry a model
  registry. `kata up --profile NAME`; an unknown name refuses to load rather than
  falling back to anything.
- **Mitigation (matching)**: entries are **literal**, not regex. The old
  hand-anchored patterns had two unescaped dots, and in a deny-by-default list an
  unescaped dot *widens* the pattern. A leading dot means "this name and any
  subdomain"; anything else is exact.
- **Mitigation (method)**: `READ_ONLY` pins hosts that have no business receiving
  a body, with a per-host path escape hatch. The important one is
  `github.com: ("/git-upload-pack",)` — fetch is a POST to that path, push is a
  POST to `/git-receive-pack`, so the gate now agrees with the project's own
  claim that the agent pushes nowhere.
- **Be honest about what the pin buys**: it removes bulk upload, not the channel.
  A GET still carries data in a path or query string, just slowly and visibly.
- Re-justify the list periodically; nothing else ever shrinks it.
- Checked by: `tests/gate.sh` D0/D6/D8/D9, `test_addon.py`.

## key-swap — spending a key the sandbox cannot read

- **L/I/S**: low / high / mitigated
- Real upstream keys live in `$UPSTREAM_KEYS_FILE` on the host (root-owned 0600;
  `net-up.sh` **refuses** anything looser, and *parses* the file rather than
  sourcing it — it is data, and `source` would run a fat-fingered edit as root).
  The guest sends the sentinel `sk-kata`; the addon substitutes the real key on
  the way upstream.
- **The one rule not to relax: the swap fires iff the presented credential is
  literally the sentinel.** Not when one is missing, not when a real one is
  present. Claude Code, Codex and Gemini CLI send OAuth bearer tokens to the same
  hosts we hold API keys for, and an unconditional inject moves a subscription
  session onto metered billing **silently** — no error, nothing in the logs.
  Booting the VM cannot catch that, because the bad case looks like success.
- The swap keys on the **gated destination**, never on the client's claim (see
  `host-spoof`: the first version of the swap read the same spoofable field, so
  `Host: api.anthropic.com` aimed anywhere installed the real key into that
  request).
- The addon logs key *names*, never values — `podman logs` is wheel-readable.
- Checked by: `test_addon.py` (both directions; the stub can hold a fake key,
  this host holds none).

## mitm-ca — the proxy is a CA the guest trusts

- **L/I/S**: low / high / partial
- mitmproxy holds a per-deployment CA private key (0600) that the guest trusts.
  Whoever reads that key can mint valid leaf certs for any allowlisted host as
  far as the guest is concerned.
- **Mitigation**: per-deployment, never shared across hosts; the private key
  never leaves the host; only the public cert is published and baked into the
  guest trust store at image-build time. The addon must never log request bodies.
- **Drift is the practical failure, not theft.** `net-up.sh` regenerates the CA
  whenever the file is missing, so a warm base can end up trusting a CA that no
  longer exists — and every TLS request in the guest then fails validation with a
  symptom that names the *proxy*, not the image. Base sidecars carry a `ca`
  fingerprint and `kata vm` refuses a drifted base (`--force` overrides).
  Empty on either side is *unknown*, never *mismatch*.
- **Open**: no automated rotation. Rotate by clearing the CA dir, re-running
  `kata up`, and re-running `kata build-base`.

## dns-raw-exfil — channels the proxy cannot see

- **L/I/S**: low / high / mitigated
- The gate only sees HTTP(S) it intercepts. Direct UDP/53 to a public resolver
  (DNS tunnelling) or raw/AF_PACKET frames would be blind spots.
- **Mitigation**: the guest needs no resolver — it reaches the proxy by IP, and
  is configured with **no default route and no nameserver at all**, deliberately.
  `agent_vm forward` is `policy drop`, so nothing off-subnet is routed, UDP/53
  included.
- **AF_PACKET**: raw frames reach only the bridge, which is not L2-bridged to any
  physical wire. A guest-internal concern rather than a host one.
- Checked by: `scripts/audit-egress.sh` T1–T4, **from inside the guest** — the
  host cannot answer these on the guest's behalf, which is why that script is
  deliberately not in `kata test`.

## nft-misconfig — the gate is only there if it is loaded

- **L/I/S**: low / high / mitigated
- If `agent_vm` is missing or the ingress accepts never landed, the guest either
  reaches the host directly or reaches nothing — and both look like a guest bug.
- **Mitigation**: `vm.sh` preflights three *independent* things and refuses on
  any of them: the bridge link, `nft list table inet agent_vm`, and a functional
  proxy check. None subsumes another (see below). `net-down.sh` is idempotent, so
  re-running `net-up.sh` resets to a known state.
- **A health check that over-claims is worse than a missing one**, because it
  makes you stop looking. `kata status`'s 403 probe proves the proxy is alive and
  the addon is loaded, from any uid — but it is issued host→loopback, so it never
  traverses the bridge or `agent_vm`. Guest-side egress is only ever proven from
  inside a guest.
- **In `vm.sh` an unexpected HTTP code is a refusal**, not a warning: anything
  other than 403 means something is listening on the proxy port that is not our
  allowlist, and the guest would boot with unfiltered egress while every
  structural check stayed green.
- Checked by: `tests/guards.sh` E1–E5.

## container-hardening — the proxy and searxng containers

- **L/I/S**: low / med / mitigated
- Rootful podman, `--network=host` bound only to the RFC1918 bridge IP,
  `--cap-drop=ALL`, `--security-opt=no-new-privileges`, known upstream images,
  under the **default** podman AppArmor profile.
- **Do not re-add `apparmor=unconfined`.** An earlier revision unconfined both
  containers on a wrong diagnosis. The real startup failure was `--cap-drop=ALL`
  colliding with the mitmproxy image's root entrypoint (a `stat` needing
  `CAP_DAC_READ_SEARCH`, then a su-exec needing `CAP_SETUID`/`CAP_SETGID`); the
  fix is `--user 1000:1000 --entrypoint mitmdump`, which skips the wrapper.

## virtiofsd-root — the one thing that cannot drop privilege

- **L/I/S**: low / high / partial
- `virtiofsd` runs **as root** and serves the agent home plus any `--rw`/`--ro`
  mount. A guest-side exploit against it lands as host root — and unlike qemu it
  cannot be dropped, because it must traverse trees the agent uid cannot.
- **Mitigation**: `--sandbox=chroot`; prefer `--ro` ingress; keep `--rw` mounts to
  data the agent actually needs.
- **Open**: no seccomp profile pinned for virtiofsd here.

## storage-persistence — the agent's home survives the session

- **L/I/S**: low / med / accepted
- `/` is a throwaway overlay, but `/home/agent` is a virtiofs pass-through to the
  key, so an implant persists. By design — real work needs persistence, and this
  is what retired the "`--to` bakes your OAuth creds into the image" trap.
- Accepted in exchange: everything under the agent home is reachable by the agent
  and can be stolen or tampered with. That is fine for OAuth session tokens
  (bounded, revocable, fixed-cost subscription) and is exactly why real API keys
  stay on the host (see `key-swap`).
- **Mitigation**: `kata disk mount` takes a read-only pre-session snapshot into a
  `root:root` subvolume the agent cannot enter, list or delete; `kata disk
  rollback` restores one.

## base-poisoning — an agent-writable base is host code exec

- **L/I/S**: low / critical / mitigated
- `vm.sh` parses base qcow2s **as root**, and qcow2 parsing is a code-execution
  surface. An agent-writable base or snapshot would therefore be a host-code-exec
  path that needs no hypervisor escape at all.
- **Mitigation**: `@bases` and `@snapshots` are you-/root-owned, **siblings** of
  the agent home and never nested under it; bases live at `$VM_BASES_DIR` on the
  host disk. The only writer is `vm.sh --to`, as root.
- This is the reason the storage layout is what it is. "Same paths, relocated
  under the agent's home" would silently delete the property.
- Cited in code as `(threat: base-poisoning)`. Checked by: `tests/unit.sh` (the
  ownership contract), `tests/MANUAL.md` (the live write attempt).

## git-interchange — one-way work return

- **L/I/S**: low / med / mitigated
- **The governing rule: trust flows one way.** Code may flow you → sandbox
  freely; the reverse is *inspect and read only*. A model pickle, a
  `trust_remote_code=True` repo or a `pip install -e .` of an agent-authored tree
  all run arbitrary code as whoever loads them. The single sanctioned return
  channel is `git fetch` — git objects are data, not executables.
- `kata git up` runs an **unauthenticated** `git daemon` on the bridge, as *you*.
  Two exposures: the sandbox writing where it shouldn't, and git's own pack
  parsing as your uid.
- **Mitigation (writes)**: only `<name>-agent.git` sets `daemon.receivepack=true`,
  so a push anywhere else is refused by git itself with `service not enabled`,
  before any object is written. `--export-all` is never passed, so a repo without
  `git-daemon-export-ok` is not served at all. `receive.maxInputSize` caps a push.
- **Mitigation (reach)**: bound to the bridge address only, never `0.0.0.0`, and
  reachable solely through the `$SANDBOX_HOST_PORTS` accepts. `kata down` closes
  the port even if the daemon keeps running.
- **The egress repo is append-only** (`receive.denyDeletes` +
  `denyNonFastForwards`). This is not branch protection — your branches were never
  reachable. It protects the **review trail**: otherwise the agent can rewrite
  history you already fetched and read, and a second `kata project pull`
  disagrees with the first for no visible reason.
- **Accepted**: pack parsing runs as your uid for data the agent controls — the
  same posture as `git fetch`-ing its tree by hand, which is what it replaces.
- Checked by: `tests/MANUAL.md` G1–G6 (needs a running guest).

## searxng-host-netns — a deliberate exception

- **L/I/S**: low / med / partial
- `kata web up` runs searxng with `--network=host` so the sandbox can search
  without reaching the VPS over tailscale — the motivating problem, since the old
  default put a confused deputy inside the tailnet.
- **What the agent gets is a query string**, sent to searxng's *configured*
  engines. It does not choose the destination, so this is not an arbitrary-URL
  fetch primitive. `image_proxy` is off for the same reason.
- **Mitigation**: `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`,
  `--user $SEARXNG_UID` (the image declares no `USER`, so without it the engine
  runs as container root), bridge-bound via `GRANIAN_HOST`, per-deployment secret
  key generated like the CA and never committed.
- **Accepted residual**: an RCE in its parsing of engine responses lands in the
  host network namespace as an unprivileged, capability-less uid.
- **Do not generalise this to firecrawl.** There the agent picks the URL, so host
  netns hands it a read primitive against loopback, the LAN and the tailnet. That
  service needs its own network position, not this one.
- Checked by: `tests/MANUAL.md` S1–S6.

## gpu-firmware-persistence — can the guest write to the card?

- **L/I/S**: low / critical / **open**
- Under `--gpu` the guest owns the real 4090 and drives it with its own NVIDIA
  driver. `nvidia-driver` below explains why that is an *improvement*. This entry
  is the question that improvement does not answer: **can a guest with full
  control of the card write persistent state to it** — VBIOS, GSP firmware?
- If it can, that state survives `kata gpu-mode host` and the reboot, and then
  the *host* driver binds a card an untrusted guest modified. The reboot's PCI
  reset clears device state; it does not clear flash.
- Signed firmware very likely prevents this on this generation. "Very likely" is
  not the standard the rest of this file holds itself to, and `--gpu` is the
  feature the project exists for.
- **Unanswered, deliberately visible.** Resolving it means establishing whether
  signature enforcement covers every writable region the guest can reach, not
  whether `nvflash` happens to refuse. Until then, treat a `--gpu` session as
  potentially permanent in a way a CPU session is not.

## kernel-cve / qemu-escape / nvidia-driver / sudo-cve — the CVE floor

- **L/I/S**: low / critical / accepted
- The guest reaches the host kernel through KVM, virtio and (under `--gpu`) VFIO.
  `vm.sh`, `net-up.sh` and `disk.sh` run under `sudo`. There is no defence here
  beyond a hardened kernel and prompt updates.
- **VFIO made one of these strictly better.** The proprietary NVIDIA module used
  to be reachable from the agent uid via a `/dev/nvidia*` ACL, so a driver bug
  landed in host ring 0. Now the host unbinds the card and loads no NVIDIA module
  at all while in sandbox mode; the driver facing the untrusted workload runs
  *inside* the guest. The residual is `vfio-pci` + the IOMMU — much smaller and
  much better audited. Do not reintroduce agent ACLs on the device nodes.
- **Interrupt remapping is the security gate for passthrough**, and it is a hard
  requirement: without it VFIO needs `allow_unsafe_interrupts=1`, which lets the
  guest inject MSIs at the host and defeats the entire project. `kata doctor
  --gpu` refuses rather than falling back. **Never add that flag to make things
  work.**
- The whole IOMMU group is passed together (a kernel requirement); `kata gpu-mode
  status` shows it, so you can confirm it holds nothing but the GPU and its audio
  function.

## The two tiers, and what "out of scope" means

"Out of scope" was doing double duty here, and after the escape report the two
meanings need separating. One of them means *someone else's problem*. The other
means *we cannot prevent this, so we bound what it costs* — and that is not the
same as not caring.

> **Tier 1 — containment.** Keep the agent in. Everything above this line.
>
> **Tier 2 — blast radius.** Assume tier 1 eventually fails. Make host root on
> *this laptop* worth as little as possible.

**Tier 2 is a real control, not a disclaimer.** `kernel-cve` is unfixable and
load-bearing; the report is an existence proof that a capable agent finds that
class of bug in hours. The only lever left is what an attacker gets on arrival.
So: personal files, keys to other machines, tailnet credentials, the password
manager and browser sessions do not belong on the machine that runs the sandbox.
Real API keys are the deliberate exception — they are on the host in
`$UPSTREAM_KEYS_FILE` precisely so the *guest* cannot read them, and they are
revocable, which is what makes that trade acceptable.

This tier's work is an **inventory**, and it is not finished: enumerate what host
root actually buys on this laptop today, and re-check it when the migration off
this machine is done. An inventory that lives in one person's head cannot tell
you when you are finished.

**Baseline, 2026-09-15 — 9 present, 13 already clear.** Gone from this laptop:
`.aws`, `.kube`, `.gcloud`, `.pypirc`, `.docker`, `.netrc`, `.password-store`,
the firefox profile, `.git-credentials`. Still here, and therefore still what an
escape buys: `~/.ssh/id_ed25519` + `known_hosts` + `config`,
`~/.config/gh/hosts.yml`, `~/.npmrc`, three chromium-family profiles, and a
running `tailscaled` (which is a credential *and* a route to everything else on
the tailnet — the single biggest item on the list).

The checker that produced those numbers was written here and then moved out to
`secproj/` on 2026-09-15: it audits the *machine*, not the boundary, and it wants
to grow in a direction this repo should not (sudo, ripgrep over the disk for key
material). The number stays here because it is the tier-2 baseline; the tool
does not.

**Genuinely out of scope** — someone else's problem, or a different project:
physical access, firmware attacks against the host, Spectre-class side channels,
multi-tenant or team use, non-Linux hosts, and hot-reloadable policy (restart the
proxy).

Don't file the tier-2 items as failures. "Accepted" everywhere above means an
intentional trade-off given exactly this model — one laptop, one user, and now an
explicit assumption that the outer wall is not permanent.
