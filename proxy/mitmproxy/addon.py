"""Egress addon for the host-side mitmproxy: hostname allowlist + upstream key swap.

mitmproxy decrypts TLS (per-deployment CA baked into the guest trust store by
build-base.sh), so everything below runs on the plaintext request, for http://
and https:// flows alike. The host list lives in allowlist.py next to this file;
we add that dir to sys.path so the import works regardless of mitmproxy's CWD.

Two jobs, in this order:

1. POLICY (allowlist.py) — deny by default, on two axes: which hosts the active
   profile contains, and which methods a read-only host accepts. A denial returns
   403 and logs the host. Read that file as an exfiltration surface, not a
   convenience list: every host on it is a channel *out* of the sandbox.

   THE HOST WE JUDGE MUST BE THE HOST WE CONNECT TO. This is `request.host`, and
   it is emphatically NOT `request.pretty_host`, which is what this addon used
   until 2026-09-13. mitmproxy documents pretty_host as "`Request.host`, but
   using the `Host` header as an additional (preferred) data source" — written
   for transparent mode, where the connection knows only an IP and the header is
   the only name available. In *regular proxy* mode the relationship inverts:
   the destination comes from the request line (or the CONNECT authority) and
   the `Host` header is an unverified claim by the client. So the gate audited
   the claim and forwarded to a destination it never inspected. Demonstrated
   from the host, against the live proxy:

       curl -x $PROXY -H 'Host: pypi.org' http://127.0.0.1:18081/   → delivered

   One header, and the allowlist is gone. Since this container runs with
   --network=host, "anywhere" includes host loopback, the LAN and the tailnet —
   and agent_isolate cannot fence that, because the socket belongs to mitmproxy
   (uid 1000) rather than to the guest. The allowlist is the only thing there.

   A claim that DISAGREES with the destination is refused outright rather than
   quietly ignored. Deciding on request.host alone would already stop the
   trivial case, but not this one: two names can share an IP, so a CONNECT to an
   allowlisted host on a shared CDN carrying `Host: attacker.example` is routed
   by the *origin* on the header we ignored. Nothing legitimate here sends a
   mismatch — the guest has no resolver and reaches everything by name through
   this proxy — so a mismatch is evidence, and it is logged as SPOOF.

   Both hooks enforce it: `http_connect` gates the tunnel before any upstream
   connection exists, `request` gates each request inside it. They call one
   function, because two copies of a check are two answers waiting to diverge.

2. UPSTREAM KEY SWAP — real provider credentials stay on the host. net-up.sh
   reads them from $UPSTREAM_KEYS_FILE (root-owned, 0600) and hands them to this
   container as environment variables; the guest presents a SENTINEL instead, and
   we substitute the real key on the way out. So a compromised sandbox can spend
   a key but never read one.

   This is all litellm was actually doing for us, minus a 30-60s cold boot, a
   second listening port, a fake-key convention per provider and a model-name
   mapping layer. Deleted 2026-09-11; see CURRENT.md step 2. What we gave up is
   cross-provider request translation (asking Anthropic in OpenAI shape) — if
   that is ever wanted, litellm comes back as an opt-in, not as permanent
   infrastructure.

   THE SWAP IS GATED ON THE SENTINEL AND NOTHING ELSE, and that gate is the
   whole safety property. We only ever overwrite a credential that is literally
   the sentinel string, so we cannot clobber the OAuth bearer tokens that Claude
   Code, Codex and Gemini CLI send to these very same hosts. Injecting
   unconditionally on api.anthropic.com would silently move a subscription
   session onto a metered API key, and injecting "when no credential is present"
   would do the same to any unauthenticated leg of an OAuth dance. Do not relax
   this to either.

   Forget to set the sentinel in the guest and you get the provider's own 401 —
   loud, self-explanatory, and not our problem to diagnose.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from allowlist import PROFILE, allowed, method_allowed  # noqa: E402  (path tweak first)
from mitmproxy import ctx, http  # noqa: E402

# What the guest sends in place of a real key. Not a secret — it is a marker,
# and it is safe in /etc/environment inside the guest. net-up.sh passes the same
# value to this container so the two halves can never drift.
SENTINEL = os.environ.get("KATA_KEY_SENTINEL") or "sk-kata"

# host -> (env var holding the real key, how that provider carries a credential)
#
#   bearer     Authorization: Bearer <key>   — OpenAI-compatible, OpenRouter
#   x-api-key  Anthropic's own header
#   x-goog     Google's x-goog-api-key header, or a ?key= query parameter
#
# Adding a provider takes three edits and all three are load-bearing: a name in
# $UPSTREAM_API_KEYS (config.sh, so net-up.sh forwards it), an entry here, and an
# allowlist.py entry — the allowlist runs first, so a host missing from it gets
# 403'd long before this table is consulted.
UPSTREAM_KEYS: dict[str, tuple[str, str]] = {
    "openrouter.ai": ("OPENROUTER_API_KEY", "bearer"),
    "api.openai.com": ("OPENAI_API_KEY", "bearer"),
    "api.anthropic.com": ("ANTHROPIC_API_KEY", "x-api-key"),
    "generativelanguage.googleapis.com": ("GEMINI_API_KEY", "x-goog"),
}


def _host_only(authority: str | None) -> str:
    """Normalise an authority to a bare hostname: no port, no case, no root dot.

    `Host` headers carry a port (`pypi.org:443`), clients vary the case, and a
    trailing dot is a legal absolute name. All three have to be folded away
    before comparison or the mismatch check fires on legitimate traffic — and a
    check with false positives is a check someone disables.
    """
    if not authority:
        return ""
    a = authority.strip().lower().rstrip(".")
    if a.startswith("["):  # IPv6 literal: [::1]:8080
        a = a.partition("]")[0].lstrip("[")
    elif ":" in a:
        a = a.partition(":")[0]
    return a


def _presented(flow: http.HTTPFlow, style: str) -> str | None:
    """The credential the client actually sent, or None."""
    h = flow.request.headers
    if style == "bearer":
        auth = h.get("Authorization", "")
        return auth[len("Bearer ") :] if auth.startswith("Bearer ") else None
    if style == "x-api-key":
        return h.get("x-api-key")
    if style == "x-goog":
        return h.get("x-goog-api-key") or flow.request.query.get("key")
    return None


def _install(flow: http.HTTPFlow, style: str, key: str) -> None:
    """Put the real key where the client put the sentinel."""
    h = flow.request.headers
    if style == "bearer":
        h["Authorization"] = f"Bearer {key}"
    elif style == "x-api-key":
        h["x-api-key"] = key
    elif style == "x-goog":
        # Replace it wherever it came from: rewriting the header when the
        # sentinel was in the query string would leave the sentinel in the URL
        # and the provider would reject the request it never saw us fix.
        if h.get("x-goog-api-key"):
            h["x-goog-api-key"] = key
        else:
            flow.request.query["key"] = key


def _reject(flow: http.HTTPFlow, status: int, msg: str) -> None:
    flow.response = http.Response.make(
        status, f"kata: {msg}\n".encode(), {"Content-Type": "text/plain"}
    )


class Egress:
    def _gate(self, flow: http.HTTPFlow) -> str | None:
        """Return the real destination host, or None having rejected the flow."""
        host = _host_only(flow.request.host)
        claimed = _host_only(flow.request.host_header)
        if claimed and claimed != host:
            ctx.log.warn(f"SPOOF {host} claimed Host: {claimed} {flow.request.method}")
            _reject(flow, 403, f"host mismatch: connecting to {host}, claiming {claimed}")
            return None
        if not allowed(host):
            ctx.log.warn(f"DENY  {host} {flow.request.method} {flow.request.path}")
            # The profile is named in the body on purpose: it is the only way to
            # read the policy the RUNNING gate is enforcing without root, which
            # is how `kata status` reports it and how drift between
            # config.local.sh and a container started an hour ago gets noticed.
            _reject(flow, 403, f"allowlist[{PROFILE}]: {host} not allowed")
            return None
        return host

    def http_connect(self, flow: http.HTTPFlow) -> None:
        """Gate the CONNECT tunnel itself, before an upstream connection exists.

        Redundant with `request` by design. It moves the refusal one round trip
        earlier for the only traffic shape that matters here (everything is TLS),
        and it does not depend on how mitmproxy propagates the tunnel authority
        into the requests inside it. Allows are not logged here — `request` logs
        every request anyway, and one line per tunnel on top is just noise.
        """
        self._gate(flow)

    def request(self, flow: http.HTTPFlow) -> None:
        host = self._gate(flow)
        if host is None:
            return

        # The method pin lives HERE and not in _gate, because http_connect's
        # method is literally CONNECT: applying it there would refuse every TLS
        # tunnel to a read-only host, i.e. all of them. The tunnel is a
        # destination question, the method is a request question.
        method, path = flow.request.method, flow.request.path or "/"
        if not method_allowed(host, method, path):
            ctx.log.warn(f"RONLY {host} {method} {path}")
            _reject(flow, 403, f"read-only: {method} {path} not allowed on {host}")
            return
        ctx.log.info(f"ALLOW {host} {method} {path}")

        # Keyed on the gated destination, never on what the client claimed: the
        # spoof above would otherwise pick the provider for us and install a real
        # key into a request bound for a host the agent chose.
        entry = UPSTREAM_KEYS.get(host)
        if entry is None:
            return
        env_name, style = entry
        if _presented(flow, style) != SENTINEL:
            # A real credential, or none at all. Never ours to touch.
            return

        key = os.environ.get(env_name)
        if not key:
            # Fail here rather than forwarding the sentinel and letting the
            # provider answer 401 — that error names the wrong problem, and the
            # wrong problem here costs an afternoon.
            ctx.log.warn(f"KEYSWAP {host}: sentinel sent but {env_name} unset on host")
            _reject(
                flow,
                502,
                f"{env_name} is not configured on the host.\n"
                f"Add '{env_name}=...' to the upstream keys file "
                f"(root:root 0600), then: kata down && kata up",
            )
            return

        _install(flow, style, key)
        # Names only, never values — this line lands in `podman logs`.
        ctx.log.info(f"KEYSWAP {host} <- {env_name}")


addons = [Egress()]
