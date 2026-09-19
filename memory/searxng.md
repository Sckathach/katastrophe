# Local search: searxng

`scripts/web.sh {up|down|status}` runs searxng on `$HOST_IP:$SEARXNG_PORT`, so
`enap search` works in the sandbox without reaching the VPS over tailscale (the
motivating problem — the old default put a confused deputy inside the tailnet).
Opt-in: `kata up` does not start it, `kata down` does stop it (it binds
`$HOST_IP`, which dies with the bridge).

Landmines, all verified against the image on 2026-07-28, not guessed:

- **`search.formats` ships as `[html]`.** `/search?format=json` returns **403**
  without the override in `web/searxng/settings.yml`. `enap` speaks only JSON, so
  a working web UI proves nothing — `web.sh up` therefore asserts a 200 on a real
  JSON query and dies on 403. Keep that check when bumping the image.
- **`server.secret_key` must not be the placeholder** — searxng `sys.exit(1)`s
  otherwise. It is *not* in the committed settings: `web.sh` generates
  `$SEARXNG_ETC_DIR/secret_key` (0600) and injects `$SEARXNG_SECRET`, which the
  settings loader overlays. So the committed file stays secret-free and 0644 —
  which it must be, since the container reads it as uid 977.
- **The image declares no `USER`** → entrypoint *and* granian would run as
  container root. `--user $SEARXNG_UID` (977, the image's own account) fixes it;
  the entrypoint's root-only branches (`chown -R`, `update-ca-certificates`) are
  then skipped and neither is needed.
- **`GRANIAN_HOST`, not `server.bind_address`.** The WSGI server reads its own
  env; the image default is `::`, which with `--network=host` would publish the
  agent's search engine on every host interface.
- **`--tmpfs /tmp` is required, not hygiene.** `ExpireCacheSQLite` defaults its
  DB to `/tmp/sxng_cache_DATA_CACHE.db` and connects during startup, so a
  read-only `/tmp` is a hard boot failure.
- `--image-volume=ignore`: the image declares `/etc/searxng` + `/var/cache/searxng`
  as VOLUMEs, which would otherwise leave an anonymous volume per run. Neither
  needs to be writable (the entrypoint only stats them).
- `server.limiter: false` is pinned even though it currently matches the
  upstream default: being rate-limited on our own queries is a silent-degradation
  failure mode, and the limiter would drag in valkey.

`--network=host` (like mitmproxy) is a **deliberate, searxng-only**
call: the agent controls the query, never the destination. Threat write-up is
`threat: searxng-host-netns`; checked by `tests/host.sh` S1 and `tests/MANUAL.md`
S2–S6. **Do not carry this shape to firecrawl** — there the
agent picks the URL, so host netns is a read primitive into loopback/LAN/tailnet.
