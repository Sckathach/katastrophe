`guest/configs/` — config for the guest, split by where it has to live.

Two destinations, and the split is not cosmetic:

- **System-wide files are baked into the image.** `scripts/build-base.sh`
  embeds them (base64) into `guest/cloud-init/user-data`, and they land under
  `/etc` on the single provisioning boot.
- **Per-user dotfiles are copied onto the storage tree** by `kata disk seed`,
  which `kata disk mount` and `kata disk local-init` call for you. They cannot
  be baked in: `/home/agent` is a **virtiofs mountpoint** at session time (the
  persistent agent home comes from the key, or from `/home/agent` on the host in
  local mode), so anything the image put there would be shadowed the moment
  the share mounts — and would then drift from the copy you actually edit.

Layout:

```
configs/
├── starship.toml              → /etc/starship.toml  (image; STARSHIP_CONFIG)
├── zsh/zshrc                  → $MOUNT_HOME/.zshrc          (seeded)
├── npm/npmrc                  → $MOUNT_HOME/.npmrc          (seeded)
├── fastfetch/config.jsonc     → $MOUNT_HOME/.config/fastfetch/  (seeded)
├── fastfetch/logo.ans         → ditto (raw ANSI — hence base64 when embedded)
├── fastfetch/word.txt         → ditto (cat'd by zshrc above fastfetch)
└── mitm-ca.pem                (gitignored; per-deployment proxy CA)
```

`seed` is **copy-if-missing**, so mounting the key never clobbers an edit made
inside a session. `kata disk seed --force` re-pushes this repo's version over
whatever is there; when both sides have moved, merge by hand — it is one repo
and two destinations (`/mnt/agent-home` and `/home/agent`), and there is no sane
automatic answer.

The **system**-wide zsh setup (plugin load order, history, PATH) is not here —
it lives in `user-data` as `/etc/zsh/zshrc`, because that order is load-bearing
(compinit → fzf-tab → fzf → zoxide → autosuggestions → syntax-highlighting →
starship). The file here is only for per-user opts, aliases, and binds.

The blank base is a shell + toolchain only. Agent CLIs (claude, codex, …) are
**not** in this repo: install them inside a session with `npm i -g` — `npmrc`
points npm's prefix at `~/.npm-global`, which is on the persistent home, so they
survive without being baked into a base. Their configs (`~/.claude`,
`AGENTS.md`, credentials) live on the home too, for the same reason.
