# Related work

Informal field notes: runtimes/tools we considered and didn't pick, and how
this compares to NVIDIA OpenShell (the closest larger project). The point is a
3-second "how is this different", plus a place to track ideas worth stealing
later. Not exhaustive, not neutral — these are choices for *this* threat model
(a single-user laptop, GPU sometimes needed, host root out of scope).

The surviving shape — qemu/KVM + virtiofs + host-kernel nft, with VFIO for the
GPU — isn't "best in the abstract". It's the one whose failure modes you can
read straight off the kernel. Two others (a rootless appliance, a rootless
podman GPU container) were deleted in 2026-08; see `knowledge/rejected.md`.

## Sandbox runtimes we rejected

- **gVisor (`runsc`)** — user-space syscall interception. No first-class GPU
  passthrough (nvproxy is experimental and lags drivers — and the NVIDIA module
  is the actual risk surface). Syscall overhead on compilers/installs is real.
  Adds a second runtime to patch. Right call for multi-tenant shared metal, not
  one laptop.
- **Kata Containers** — a tiny VM per container. By the time you've paid for the
  guest kernel + init + agent + virtio-fs, you *have* the VM path — but with
  another orchestrator (`containerd-shim-kata`) to audit. Its GPU story rides
  the same host CDI plumbing as rootless podman, so the VM boundary doesn't
  shield an in-driver compromise — which is exactly the problem VFIO solves
  here by removing the host driver from the path entirely.
- **Firecracker** — no virtio-fs (block only), so sharing the agent home becomes a
  9p/tarball hack; "edit on host, run in sandbox" is the whole point.
- **Cloud Hypervisor** — *does* have virtio-fs and would be a reasonable swap-in
  for microVM boot speed. We stayed on qemu only because it's everywhere, KVM is
  the ring-0 piece we trust, and the qemu CLI is well-trodden. Revisit if boot
  time/RAM across many VMs ever matters.
- **bubblewrap / unshare-only** — no network isolation that holds if the agent
  breaks seccomp or finds a kernel bug. The host-kernel skuid drop fires in
  ring 0 regardless of what happens inside the userns; bwrap can't offer that.
- **LXC / systemd-nspawn** — `nspawn` defaults expose more host (DBus, journald)
  than wanted; locking it down just reproduces a container boundary we decided
  was too weak for this workload anyway.
- **Qubes-style** — wrong granularity (a permanent AppVM/NetVM split of the
  whole desktop), and its value *is* not trusting host root, which this model
  already accepts as out of scope.
- **NVIDIA vGPU / MIG / SR-IOV** — consumer GPUs have none of it; licensing is
  hostile even on datacenter parts. Ruled out, which is what leaves **full VFIO
  passthrough** as the only way to give a VM real CUDA. The cost is that the GPU
  is all-or-nothing and switching sides takes a reboot; the benefit is that the
  host loads no NVIDIA driver at all while the sandbox runs.
- **CDI / rootless podman for GPU** (what this used to do) — gives the agent
  CUDA cheaply and switches instantly, but the boundary is user namespaces and
  the host's NVIDIA module sits directly under the untrusted workload. Traded
  away deliberately.

## Egress-gate choices

- **nftables over iptables** — atomic ruleset reloads (`nft -f` all-or-nothing)
  and one tool for v4+v6; the punch-through dance in `net-up.sh` is cleaner with
  named, commented tables.
- **skuid filtering over cgroup `net_cls`/BPF** — the agent uid is already a
  stable tag (qemu drops to it after init), so a skuid rule is a one-liner; no
  BPF program to write and pin. Note the scope changed with the one-runtime
  refactor: skuid no longer gates the sandbox's *traffic* (that arrives on the
  bridge and is filtered by `agent_vm`), it gates what an **escaped qemu** could
  do. Which is why `agent_isolate` now needs no exceptions at all.
- **mitmproxy over tinyproxy** (the switch that defined the egress gate) —
  tinyproxy did SNI-layer hostname allowlisting in ~6k lines of C, but can't
  decrypt TLS, so it can't do L7 method/path rules, can't swap an upstream API
  key, and can't expose plaintext LLM messages to anything. Terminating TLS is
  what buys `READ_ONLY` pinning and the sentinel key swap.
- **mitmproxy over Privoxy/Squid** — those are full web proxies (more code, more
  knobs, more ways to misconfigure the allowlist). The addon is one short Python
  file.

## Image build

- **Ubuntu cloud image + cloud-init over a Nix flake** — reversed in 2026-08.
  The flake was genuinely tidier for a blank shell image, but the workload here
  is ML: binary wheels, CUDA, `pip install` of things with vendored `.so`s.
  That's NixOS's worst case, and the escape hatch (`uv`) broke the
  reproducibility that was the reason to use Nix in the first place. The agents
  that live in this VM also know `apt`, not `configuration.nix`. cloud-init is
  an extra debug layer, but it runs exactly once at build time and the artifact
  is a plain qcow2.
- **cloud-init over packer / virt-customize** — packer needs SSH up first;
  virt-customize drags in libguestfs. A NoCloud seed ISO plus one throwaway boot
  needs neither, and the provisioning boot doubles as a smoke test of the image.
- **Integrity: verify, and let you pin.** The cloud image is checked against
  Ubuntu's published `SHA256SUMS` and the digest is printed so you can hard-pin
  it in `config.local.sh`. Unpinned is trust-on-first-use, and `build-base.sh`
  says so rather than implying a pin it doesn't have.

## vs NVIDIA OpenShell

OpenShell is the closest larger project — worth tracking for ideas. It's
enterprise-shaped (gateway + sandbox + gRPC + persistent DB + multiple compute
drivers + mTLS PKI, ~41k LoC Rust in the core crates); this is laptop-shaped (a
few thousand lines of bash plus ~200 lines of Python). Different points on the complexity/value
curve, different threat models — **not** a migrate-wholesale target.

**What only this has (the reasons not to switch):**

- **The persistent host-kernel `agent_isolate` skuid drop.** OpenShell's
  outermost boundary *is* the libkrun VM / container — if that's breached,
  there's nothing underneath. Here, an escape that's still uid 1001 hits a
  ring-0 nft drop to RFC1918/tailnet/link-local regardless of the runtime. This
  is the single biggest delta vs every off-the-shelf sandbox.
- **OAuth subscription CLIs (Claude Code, Gemini CLI) as first-class.**
  OpenShell's provider model is API-key only (`*_API_KEY` env vars); the OAuth
  dance isn't modelled. Here it's handled via the allowlist + per-deployment CA,
  accepting that OAuth creds live in the sandbox.
- **Room for a probe that hosts a Python model.** The mitmproxy addon is
  ordinary Python running on post-MITM plaintext, so an interpretability check
  can live there directly. OpenShell's OPA Rego is a decision language, not a
  place to run a model — you'd be shelling out to a sidecar. (Ours is parked, not
  shipped — see `knowledge/rejected.md`. This is a property of the shape, not a
  feature we currently have.)
- **No persistent control plane.** `kata down` and the host is back to "nothing
  running". OpenShell keeps a gateway daemon + per-sandbox supervisor + PKI — all
  latent surface during off-hours.

**What OpenShell does better (ideas to watch / grab):**

- ~~**L7 method/path policy**~~ — **taken, 2026-09-13.** `READ_ONLY` in
  `proxy/mitmproxy/allowlist.py` is the host + access-mode subset of their
  schema, plus a per-host path escape hatch so `git fetch` works and `git push`
  does not. We borrowed the schema shape and not the OPA engine, as planned.
  Still theirs: per-`binary` pinning (see TOFU below).
- **Per-sandbox ephemeral CA** generated *per VM build* rather than once per
  host — strictly better hygiene (a leaked CA can't decrypt another session).
  Mostly a tweak to where `net-up.sh` mints the cert.
- **Trust-on-first-use binary identity** at the proxy (resolve the calling PID
  via `/proc/net/tcp` → pin the binary hash, so a compromised dep can't start
  using an allowlisted host). Hard for us — the proxy runs *outside* the VM and
  can't see in-guest PIDs without a sidecar. Skip unless the proxy moves in-guest.
- **Structured audit log** (they use OCSF). Ours is `ctx.log` lines read with
  `podman logs -f agent-proxy` — fine for one user; revisit a real schema if
  tuning the allowlist from history becomes a thing. Whatever replaces it must
  keep the two existing rules: log the **gated destination**, never the client's
  claim (`threat: host-spoof`), and log key *names*, never values.
- **SSRF / hard-blocked IMDS ranges in the proxy** (`169.254.169.254`, RFC1918).
  We already get this in ring 0 via `agent_isolate` + `agent_vm` default-drop —
  **don't borrow**, ours is stronger.

**What would change the calculus:** going API-key-only (then their provider
model + `inference.local` + L7 policy is a real win, and you'd mainly give up
the skuid layer); the probe becoming a Rego-style ruleset instead of a model
(then OPA is in scope); or wanting multi-user/team sandboxing (single-user here
by construction). None true today.

## Not seriously considered

Docker/Rancher Desktop (adds a VM to host a runtime we already have rootless),
Snap/Flatpak (desktop-app shape, portals), Anbox/WSL (irrelevant), cloud
enclaves (Nitro / Confidential VMs — cloud only).
