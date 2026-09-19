# The egress gate

Host nftables + a TLS-terminating mitmproxy. This file covers the host-side
plumbing (which chains, which ports, which firewall), the IPv6 trap that looks
exactly like a broken allowlist, and the policy the addon enforces.

The threats these implement are `agent-isolate`, `nft-misconfig`, `host-spoof`,
`allowlist-drift` and `key-swap` in `knowledge/threat-model.md`.

## Host ports the sandbox may reach (`SANDBOX_HOST_PORTS`)

Every host service the sandbox talks to needs a hole in **two** chains, because
`drop`/`reject` is terminal across chains at the same hook: `filter input` (the
host's own main chain) + `agent_vm input` (the session gate). The list lives
once, in `config.sh:SANDBOX_HOST_PORTS`, and `net-up.sh` loops over it.

**It was four chains until 2026-08-01.** The other two were `agent_uid_egress
output` (the GPU container's session gate — table deleted with that runtime) and
`agent_isolate output`. Dropping the latter is a real **tightening**, and it's
worth understanding so nobody "restores" it: `agent_isolate` drops
`skuid=1001 → RFC1918`, and `10.201.0.1` is in `10/8`. The container's host
sockets carried skuid 1001, so it needed exceptions to reach the proxy at all.
The VM's traffic arrives over the bridge carrying **no** skuid, and qemu itself
(running as 1001 after `-run-with`) opens no TCP. So an escaped qemu can now
reach none of mitmproxy/git-daemon/searxng. `net-up.sh` still *purges*
`alt-proxy-exception` rules so upgrading from an older checkout actually tightens
instead of leaving stale holes.

**Trade-off to remember: `nft/agent_sandbox.nft` is no longer readable as the
whole policy** — the per-port accepts aren't in it. Use `kata status --rules`
instead of trusting the template. Adding a service = add the port var + append
it to `SANDBOX_HOST_PORTS`; touch no nft file. net-up.sh deletes-then-reloads
the session table so a re-run replaces rules instead of stacking a second copy.

One consequence worth internalising: adding a port to the list is not enough if
`kata up` already ran — the rules are inserted at up time. `web.sh` warns when
its port is missing from `agent_vm input` for exactly this reason; do the same
in any new service script.

**`inet filter` is not universal (fixed 2026-08-01).** net-up.sh used to insert
the ingress accepts into `inet filter input` unconditionally. That chain is the
Arch/stock-nftables layout; a host running **ufw or firewalld** filters in the
`ip`/`ip6` families and has no `inet filter` table at all, so the insert is a
hard error and `set -e` aborted the whole script — `kata up` died there, leaving
`agent_vm` with no port accepts and both proxies unstarted. Now the punch-through
is conditional on the table existing, and when it doesn't we check the host
firewall instead (ufw: assert an `ALLOW IN` on the bridge, else print the exact
`ufw allow in on virbr-agent` to run). A broad upstream allow on the bridge is
fine — `agent_vm input` still ends in a terminal drop, and drop wins across
chains at the same hook.

**This host is that host**, and the rule was missing (run 04). It's installed
now — `ufw allow in on virbr-agent`. Symptom if it ever goes away: `kata up`
succeeds, everything in `kata status` is green, and the guest still reaches
nothing, because ufw drops on the way in before `agent_vm input` is consulted.
The warning net-up.sh prints is the only thing that names it, so read the up
output rather than trusting the verify summary. Adding it automatically was
considered and rejected: it's the host's global firewall, not ours.

## The IPv6 trap (2026-08-01) — read this before debugging "the proxy is broken"

Symptom: from inside the sandbox, `github.com` is instant and `pypi.org` hangs
forever. It reads like a broken allowlist or a wedged proxy. It is neither.

**mitmproxy has no Happy Eyeballs.** It connects upstream through Python
asyncio, which calls `getaddrinfo(3)` and then tries the returned addresses *in
order*, waiting out the kernel connect timeout on each. `curl` races v4 and v6
(RFC 8305) and shrugs off a dead IPv6 path; mitmproxy sits there. So on a host
that **advertises IPv6 but cannot route it** — RAs arrive, the upstream is dead
— every allowlisted host with a AAAA record hangs and every IPv4-only host is
fine. This laptop's wifi is exactly that.

The discriminator that pins it in ten seconds, all from the host:

```bash
curl -x http://10.201.0.1:8080 http://github.com/              # 301, 0.25s (no AAAA)
curl -x http://10.201.0.1:8080 http://pypi.org/                # hangs   (has AAAA)
curl -x http://10.201.0.1:8080 http://nonexistent.astral.sh/   # 502, 0.1s → DNS is fine
curl -x http://10.201.0.1:8080 http://example.com/             # 403     → allowlist is fine
ping -6 -c2 2001:4860:4860::8888                               # 100% loss → there it is
```

Two fixes, both shipped, covering different scopes:

- `proxy/mitmproxy/gai.conf`, mounted at `/etc/gai.conf` in the container, makes
  glibc return IPv4 first **for the proxy only**. The sandbox's egress no longer
  depends on host IPv6 being healthy. Note the format trap: per `gai.conf(5)` a
  single `precedence` line **discards the entire built-in table**, so the file
  carries the full default table with one value changed. Don't trim it.
- `/etc/sysctl.d/99-kata-no-broken-ipv6.conf` (written by `.claude/scripts/06`)
  sets `accept_ra=0` + `autoconf=0` **on wlan0 only**. Not
  `all.disable_ipv6=1` — tailscale0 carries a ULA and uses v6 for its own mesh.
  Delete that file if you move somewhere IPv6 works; nothing will remind you.

Corollary for `kata status`: `podman container exists` is worthless as a health
check — it stayed true for a proxy that accepted TCP and answered nothing. It
now issues a real request the allowlist must **deny** (403), which exercises the
addon and never leaves the machine.

## Upstream API keys: the shell is a dead end (`UPSTREAM_KEYS_FILE`)

*(2026-08-02; litellm deleted 2026-09-11 — the lesson below outlived it
unchanged, only the consumer moved.)*

Instance 1 of the rule above. `net-up.sh` used to forward `$ANTHROPIC_API_KEY`
& co. into the container straight from its own environment, which could never
have worked from the normal entrypoint.

Now the canonical source is `$UPSTREAM_KEYS_FILE`
(`/etc/agent-proxy/upstream-keys` — was `/etc/agent-litellm/env`; net-up.sh
prints the `sudo mv` if it finds the old one), `KEY=value` lines, **root-owned 0600 — net-up.sh refuses anything looser** and
says so, rather than warning and continuing; a secrets file the agent uid can
read defeats the point of keeping keys off the guest. It is **parsed, not
sourced**: the file is data, and `source` would execute a fat-fingered edit as
root. The process environment stays a fallback, so running the script directly
or under `sudo -E` still works. `net-up.sh` prints the key **names** it loaded
(`[*] upstream keys: …`) — never values, that line lands in terminals and logs.

The name list is `$UPSTREAM_API_KEYS` in config.sh. Adding a provider is three
edits and all three are load-bearing: a name there, an entry in `addon.py`'s
`UPSTREAM_KEYS` (which host, and how that provider carries its credential), and
an `allowlist.py` host — the allowlist runs first, so without it the host is
403'd before the swap is ever consulted. `.claude/scripts/08-upstream-keys.sh`
creates the file with the right mode.

### The swap itself, and the one rule not to relax

The keys go into the **mitmproxy container**, not a router. The guest sends
`$KEY_SENTINEL` (`sk-kata`) as its credential; `proxy/mitmproxy/addon.py`
substitutes the real key on the way upstream. So the sandbox can spend a key it
can never read, with no second service, no second port, and no model-name
mapping. This is all litellm was doing for us; what we gave up is cross-provider
request translation, and if that is ever wanted litellm comes back as an opt-in.

**The swap fires iff the presented credential is literally the sentinel.** Not
when one is missing, not when a real one is present. That gate is the whole
safety property: Claude Code, Codex and Gemini CLI send OAuth bearer tokens to
`api.anthropic.com` / `api.openai.com` /
`generativelanguage.googleapis.com` — the same hosts we hold API keys for — and
an unconditional inject there moves a subscription session onto metered billing
**silently**, with no error and nothing in the logs. Booting the VM cannot catch
that, because the bad case looks like success. `proxy/mitmproxy/test_addon.py`
is 47 checks over exactly this, the `Host:` rule and the profiles below (stubs the mitmproxy
module, no deps, runs anywhere: `python3 proxy/mitmproxy/test_addon.py`). Same reason the guest's
`/etc/environment` pre-sets only `OPENROUTER_API_KEY=sk-kata` and deliberately
leaves the other three unset — those CLIs prefer an API key over a subscription
session when one is present. Export the sentinel per-command for API mode.

The old Codex trap (`OPENAI_BASE_URL=http://10.201.0.1:4000/v1` exported
globally, misrouting its OAuth into litellm, had to be unset by hand) is gone
with the service. `NO_PROXY=10.201.0.1` **stays** in the guest, and is not
litellm's: it covers the whole host IP, where searxng and the git daemon also
live.

## The gate judges the DESTINATION, never the `Host:` header (2026-09-13)

The worst bug this project has had. `addon.py` allowlisted
`flow.request.pretty_host`, and mitmproxy documents that as *"`Request.host`,
but using the `Host` header as an additional (**preferred**) data source"*. So
the gate audited a name the client chose and forwarded to a destination it never
looked at. One flag:

```sh
curl -x $PROXY -H 'Host: pypi.org' http://127.0.0.1:18081/exfil-proof   # delivered
```

**The blast radius is not exfiltration, it is the whole isolation claim.** The
proxy runs `--network=host`, so "any destination" includes host loopback, the
LAN and the tailnet — the three things the README promises the agent cannot
reach. `agent_isolate` cannot help: the socket belongs to **mitmproxy as uid
1000**, not to the guest, so the skuid drop never sees it. The allowlist was the
only control on that path. And the key swap picked its provider from the same
field, so `Host: api.anthropic.com` aimed at an agent-chosen host installed the
real key into that request — "spend a key but never read one" inverted.

Four lessons, in descending order of how much they generalise:

- **A monitor that reads attacker-controlled data reports the attacker's
  story.** `podman logs` printed `ALLOW pypi.org GET /exfil-proof` for traffic
  that went to loopback. Not a missing log — a *confidently wrong* one, which is
  worse, and the same family as the `sudo -n` probe and `podman container
exists`: the instrument was not measuring what its name claimed.
- **When a library offers a convenient accessor and a strict one, the convenient
  one usually encodes an assumption about who is allowed to lie to you.**
  `pretty_host` is correct for *transparent* mode, where the connection knows
  only an IP and the header is the only name there is. We used it in *regular*
  proxy mode, where that trust relationship is exactly inverted. The bug is
  ours, not mitmproxy's.
- **Judging the real host is necessary but not sufficient**, which is why a
  disagreement is refused outright. Two names can share an IP, and a shared
  origin (`*.run.app`, HF Spaces, GitHub Pages, any CDN) routes on the `Host`
  header we would have ignored — so an allowlisted CONNECT target plus a foreign
  `Host` still reaches attacker-controlled content. Nothing legitimate here ever
  sends a mismatch: the guest has no resolver and reaches everything by name
  through this proxy. It is pure signal, logged as `SPOOF`.
- **Normalisation is part of the control, not tidying.** Every HTTPS request
  sends `CONNECT name:443` with `Host: name:443`, so without `_host_only`
  stripping the port, *all TLS* would read as a spoof. A mismatch check with
  false positives is a mismatch check someone deletes.

Enforced in **one** function (`Egress._gate`) called from two hooks:
`http_connect` refuses the tunnel before any upstream connection exists, and
`request` covers each request inside it. One function on purpose — see the
duplicated-probe rule in `knowledge/sessions.md`.

Regression cover, and note the split, because neither half is sufficient:
`proxy/mitmproxy/test_addon.py` (stubbed, offline, and it is where the stolen-key
case is proven — the stub can hold a fake `ANTHROPIC_API_KEY`, this host holds
none) and `tests/gate.sh` (D0–D5, the gate **as deployed**, unprivileged; the
only suite that can tell you `/etc/agent-proxy/addon.py` is the file in the repo
and that the container was restarted after you edited it). D3 asserts
**non-arrival** at a loopback listener rather than the 403, because the 403 was
never the property.

## Allowlist profiles + read-only pinning (`ALLOWLIST_PROFILE`, 2026-09-13)

`allowlist.py` was one flat union of every workflow: a SWE session that would
never touch a model registry still had `huggingface.co` and
`storage.googleapis.com` open. It is now **groups composed into profiles**,
selected by `$ALLOWLIST_PROFILE` / `kata up --profile NAME`, which net-up.sh
forwards as `KATA_ALLOWLIST_PROFILE` into the container:

| profile | groups | for |
| --- | --- | --- |
| `swe` (default) | system + dev + agents | README workflow 1 |
| `research` | + models (HF, pytorch, NVIDIA) | workflow 2; `kata-install-cuda` needs it |
| `local` | system only (apt) | workflow 3 — llama.cpp/searxng/firecrawl are on the host behind `NO_PROXY`, so they never touch the gate |

Four decisions in there worth not undoing:

- **Matching is literal, not regex.** Every old entry was a hand-anchored
  `^example\.com$`, and two of the ~35 had **unescaped dots** — in a
  deny-by-default list an unescaped dot *widens* the pattern, and
  `daily-cloudcode-paXgoogleapis.com` is registerable. A leading dot now means
  "this name and any subdomain"; anything else is exact. That retires the bug
  class instead of fixing two instances. (It did cost a hair of precision:
  `^([a-z]{2}\.)?archive\.ubuntu\.com$` became `.archive.ubuntu.com`, i.e. any
  Ubuntu-controlled subdomain. Fine, but note it rather than discover it.)
- **An unknown profile refuses to load.** `raise SystemExit` at import → the
  addon fails → mitmproxy never binds → net-up.sh prints the container log.
  net-up.sh *also* asks `allowlist.py --check` first, purely for a readable
  error; the list of valid names stays in the one file that knows it. A typo
  falling back to something permissive would be the worst outcome, and falling
  back to something **empty** is nearly as bad — it presents as a broken proxy
  rather than as a typo.
- **`READ_ONLY` pins the hosts that have no business receiving a body**, with a
  per-host escape hatch for path suffixes. The important one:
  `github.com: ("/git-upload-pack",)` — git *fetch* is a POST to that path, git
  *push* is a POST to `/git-receive-pack`, so allowing exactly the first makes
  the gate agree with what the project already claims (the agent pushes nowhere;
  work comes back via `kata project pull`). Without it, a token in the guest
  makes `github.com` an unlimited exfil channel that looks like ordinary
  developer traffic. `api.github.com` is reads-only for the same reason (gists
  and issues are text-shaped write endpoints), and `storage.googleapis.com` —
  a general object store, on the list only for a Gemini config fetch — is the
  single worst entry on the allowlist and is now `GET`/`HEAD` only.
  **Be honest about what this buys:** it removes bulk upload, not the channel. A
  GET still carries data in a path or query string, just slowly and visibly.
- **The method pin is enforced in `request`, never in `_gate`.** `http_connect`'s
  method is literally `CONNECT`, so checking it there would refuse every TLS
  tunnel to a read-only host — i.e. all of them. The tunnel is a *destination*
  question; the method is a *request* question.
- **The provider APIs stay unpinned**, and there is a test asserting it: a chat
  completion is a POST. Pinning those would break the sandbox outright, and the
  only real lever for that group is not including it (that is what `local` is).

**The deployed profile is read out of the gate, not out of config.sh.** The 403
body is `kata: allowlist[swe]: <host> not allowed`, `proxy_profile()` in `lib.sh`
parses it, and `kata status` shows it — flagging it when it disagrees with
`$ALLOWLIST_PROFILE`, because editing `config.local.sh` and forgetting `kata up`
is otherwise invisible. Same principle as the CA fingerprint in base sidecars:
ask the thing that is running, not the thing that describes it.

Audit view, no deps, and useful before touching the list:

```sh
python3 proxy/mitmproxy/allowlist.py            # active profile, annotated with the pins
python3 proxy/mitmproxy/allowlist.py research   # any other profile
```
