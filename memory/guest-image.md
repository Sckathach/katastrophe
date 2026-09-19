# Guest image (Ubuntu 24.04 + cloud-init)

`guest/cloud-init/user-data` replaces the old `nixos/{common,configuration}.nix`.
It is consumed **once**, by `build-base.sh`; sessions boot with cloud-init
disabled (`/etc/cloud/cloud-init.disabled`), so none of it re-runs.

Non-obvious things in there, all load-bearing:

- **cloud-init module order.** `write-files` → `ca-certs` → `users-groups` all
  run in the *init* stage, before `apt`/`packages` (config stage) and before
  `runcmd` (final stage). The consequence still relied on: the CA is trusted
  before apt runs, so apt can use the TLS-terminating proxy.
- **Nothing writes under `/home/agent`** — it's a virtiofs mountpoint at session
  time. That also retired the old `chown -R agent:agent /home/agent` in
  `runcmd`, which existed because write-files lands root-owned before the user
  exists. If you find yourself adding a file there, it belongs in
  `guest/configs/` + `disk.sh:seed_rows` instead.
- **No proxy during the build.** The provisioning boot is on qemu SLIRP with
  plain NAT; `$HOST_IP` doesn't exist yet. So the apt proxy directive and the
  static netplan are written at the **very end** of `runcmd`. Anything you add
  that needs network must go before that line. This is also why `kata
  build-base` needs neither `kata up` nor the allowlist to know about
  nodesource/starship.rs/astral.sh.
- **apt ignores `HTTP_PROXY`.** It needs
  `/etc/apt/apt.conf.d/99katastrophe-proxy`. Without it every apt call in the
  sandbox hangs until it times out.
- **Everything embedded is base64** (`encoding: b64`) except the CA. `logo.ans`
  is raw ANSI with escape bytes and cannot survive being pasted into YAML as
  text. The CA has to be plain text under a block scalar, so `build-base.sh`
  re-indents it in Python — that's why templating is a Python heredoc and not
  `sed`.
- **`VM_DISK_SIZE` is used twice and the two must agree**: `build-base.sh` grows
  the cloud image before the provisioning boot (so cloud-init's growpart expands
  the fs), `vm.sh` creates the session overlay at the same size.
- **Debian renames binaries**: `fd-find`→`fdfind`, `bat`→`batcat`. Symlinked in
  `runcmd`. And `fzf --zsh` only exists from fzf 0.48 while 24.04 ships 0.44, so
  `/etc/zsh/zshrc` falls back to sourcing the widget files.
- **Static IP, matched by glob** (`match: {name: "en*"}`), not a fixed
  `enp0s3` — the virtio-net name shifts with PCI slot, and adding a VFIO GPU
  changes the topology. Pinning it stalled boot once already.
- **No default route, no nameserver**, deliberately. Everything off-subnet is
  dropped by `agent_vm forward` anyway and the proxy does all resolution;
  configuring an unreachable resolver only converts fast failures into slow ones.
- snapd + unattended-upgrades are purged: useless here, and both generate egress
  the allowlist would otherwise have to permit.
