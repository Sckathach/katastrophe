# Working in this sandbox

You are in a disposable VM. This file is the toolbox and the boundaries.

## What persists and what does not

**`/home/agent` is a host directory** shared in over virtiofs. Everything else: `/`, `/usr`, `/etc`, `/var` — is a disposable overlay that is **deleted at poweroff**.

## Network

All egress goes through a TLS-terminating proxy on a **hostname allowlist**, so a request to an unlisted host returns **403 from the proxy, not a DNS error**. There is no DNS and no default route in here; the proxy resolves everything.

`curl`/`pip`/`npm`/`apt` are all pre-configured for the proxy. `xh` inherits `HTTPS_PROXY` too.

## Shell toolbox

These are installed. Prefer them to the POSIX defaults, and prefer a one-line invocation to a script someone has to maintain.

`rg` content search (not `grep -r`) · `fd` filename search (not `find`) ·
`sd` search/replace (not `sed`) · `ast-grep` structural code search and rewrite ·
`tree` · `jq` JSON · `dasel` YAML/TOML/JSON/XML · `mlr` CSV/TSV/JSON records ·
`sqlite3` · `xh` HTTP (not `curl`) · `monolith` freeze a page to one HTML file ·
`websocat` · `grpcurl` · `watchexec` rerun on change · `just` · `pre-commit` ·
`hyperfine` benchmarking · `shellcheck` · `shfmt` · `eslint` · `lsof` · `strace` ·
`procs` (ps) · `btm` (top) · `dust` (du) · `duf` (df) · `tokei` LOC by language

Also present: `uv` (Python — prefer it to `pip`/`venv`), `nvim`, `fzf`, `zoxide`, `eza`, `bat`, `git`, `node`/`npm`, `python3`, `fastfetch`.

Non-obvious:

- `rg` and `fd` respect `.gitignore`; pass `-u` / `-I` to search ignored files.
- `sd` patterns are literal by default, unlike `sed`: `sd 'old' 'new' $(rg -l old)`.
- `ast-grep` is for what regex gets wrong: a call shape, a decorator, a type
  annotation. Invoke it as `ast-grep`; `sg` may be shadowed by shadow-utils.
- `dasel` v3 syntax is `-i <fmt> -o <fmt>`; most online examples show v1's
  `-f`/`-r`/`-w` and will not work.
- For JSON use `jq`, which is more expressive. Never `dasel -o json | jq`.
- `mlr` is invoked as `mlr`, not `miller`.
- No markdown-aware query tool; strip the fences to read YAML frontmatter:
  `awk '/^---$/{n++;next} n==1' file.md | dasel -i yaml -o json 'tags'`
- Any claim about speed comes from `hyperfine`, never from `time`.
- Run `shellcheck` and `shfmt` on every shell script before considering it done.
