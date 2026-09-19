#!/usr/bin/env python3
"""Tests for addon.py — run with `python3 proxy/mitmproxy/test_addon.py`.

No framework, no dependencies, and deliberately no installed mitmproxy: the
module is stubbed below so this runs on the host, in CI, or anywhere else
without pulling a proxy's dependency tree in. The addon only uses
`http.Response.make` and `ctx.log`, which is a small enough surface to fake
honestly.

Two properties are protected here, and each is one the live sandbox cannot
show you — a booted VM looks identical in the good and bad case.

    1. the gate judges the host it will CONNECT to, never the Host: header
    2. the key swap fires if and only if the client presented the sentinel

(1) was a real bypass, fixed 2026-09-13: the addon read `request.pretty_host`,
which prefers the client's `Host` header, so `curl -x $PROXY -H 'Host: pypi.org'
http://127.0.0.1:18081/` was allowed and delivered. The stub below therefore
does NOT define `pretty_host` at all — a regression to it is an AttributeError
here rather than a silent hole in production.

Everything else in the addon is a lookup. The sentinel condition is what keeps an
unconditional injection from silently moving a Claude Code / Codex / Gemini CLI
OAuth session onto a metered API key — a failure that costs money, produces no
error, and would be invisible in the logs. It cannot be verified by booting the
VM either, because the bad case looks like success. So it gets a test.
"""

# Faking a module means assigning attributes a ModuleType does not declare;
# that is the technique, not a mistake.
# pyright: reportAttributeAccessIssue=false, reportArgumentType=false

from __future__ import annotations

import os
import sys
import types
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))

# --- stub mitmproxy -------------------------------------------------------
# Must be installed in sys.modules BEFORE importing addon, which does
# `from mitmproxy import ctx, http` at module level.


class _Response:
    def __init__(self, status: int, body: bytes, headers: dict):
        self.status_code, self.content, self.headers = status, body, headers

    @staticmethod
    def make(status=200, content=b"", headers=None):
        return _Response(status, content, headers or {})


class _Log:
    def __init__(self):
        self.lines: list[str] = []

    def info(self, m):
        self.lines.append(f"info {m}")

    def warn(self, m):
        self.lines.append(f"warn {m}")

    def error(self, m):
        self.lines.append(f"error {m}")


_mitm = types.ModuleType("mitmproxy")
_mitm.http = types.SimpleNamespace(Response=_Response, HTTPFlow=object)
_mitm.ctx = types.SimpleNamespace(log=_Log())
sys.modules["mitmproxy"] = _mitm
sys.modules["mitmproxy.http"] = _mitm.http
sys.modules["mitmproxy.ctx"] = _mitm.ctx

sys.path.insert(0, HERE)
os.environ.setdefault("KATA_KEY_SENTINEL", "sk-kata")
os.environ["OPENROUTER_API_KEY"] = "sk-or-REAL"
os.environ["ANTHROPIC_API_KEY"] = "sk-ant-REAL"
os.environ["GEMINI_API_KEY"] = "AIza-REAL"
os.environ.pop("OPENAI_API_KEY", None)  # the "configured nowhere" case

import addon  # noqa: E402


# --- fake flow ------------------------------------------------------------
class _Query(dict):
    """mitmproxy's request.query is a dict-like over the URL query string."""


class _Flow:
    """`url` is where the request really goes; `Host:` in headers is the claim.

    A real client sends a Host header matching the URL, so that is the default —
    which makes every spoof test in this file an explicit, visible disagreement
    rather than something that could happen by omission.
    """

    def __init__(self, url: str, headers: dict | None = None, method: str = "GET"):
        parts = urlparse(url)
        hdrs = dict(headers or {})
        self.request = types.SimpleNamespace(
            host=parts.hostname,  # the destination: request line / CONNECT authority
            host_header=hdrs.get("Host", parts.netloc),  # the claim (may carry :port)
            method=method,
            path=parts.path,
            headers=hdrs,
            query=_Query({k: v[0] for k, v in parse_qs(parts.query).items()}),
        )
        self.response = None


# --- harness --------------------------------------------------------------
FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}  {detail}")
        FAILS.append(name)


def run(url: str, headers: dict | None = None, method: str = "GET") -> _Flow:
    f = _Flow(url, headers, method)
    addon.Egress().request(f)
    return f


def run_connect(url: str, headers: dict | None = None) -> _Flow:
    f = _Flow(url, headers)
    addon.Egress().http_connect(f)
    return f


def rejected(f: _Flow, status: int, needle: bytes) -> bool:
    return f.response is not None and f.response.status_code == status and needle in f.response.content


print("allowlist")
f = run("https://pypi.org/simple/")
check("allowed host passes", f.response is None)
f = run("https://evil.example.com/x")
check("denied host gets 403", f.response is not None and f.response.status_code == 403)
check(
    "denial happens before any key logic",
    b"allowlist" in (f.response.content if f.response else b""),
)

print("\npolicy — profiles and literal matching")
import allowlist  # noqa: E402  (after the stub, like addon)

check("the default profile is the narrow-ish one", allowlist.PROFILE == "swe")
check("a model registry is NOT in swe", not allowlist.allowed("huggingface.co"))
check("...and IS in research", "huggingface.co" in allowlist.hosts("research"))
check("the local profile is apt and nothing else", allowlist.hosts("local") == allowlist.GROUPS["system"])

# Matching is literal + ".suffix", which retires a class of bug rather than an
# instance: two of the old hand-written regexes had unescaped dots, and in a
# deny-by-default list an unescaped dot WIDENS the pattern to any character.
check("a leading dot matches a subdomain", allowlist.allowed("raw.githubusercontent.com"))
check("a leading dot matches the apex too", allowlist.allowed("astral.sh"))
check("an unescaped-dot lookalike is denied", not allowlist.allowed("daily-cloudcode-paXgoogleapis.com"))
check("a suffix is not a substring", not allowlist.allowed("evil-githubusercontent.com"))
check("our name as someone else's subdomain is denied", not allowlist.allowed("github.com.evil.example"))
check("case and a trailing root dot are folded", allowlist.allowed("PyPI.org."))

# A bogus profile must stop the proxy from starting at all. Silently falling back
# to something permissive would be the worst outcome; silently falling back to
# something EMPTY is nearly as bad, because it presents as a broken proxy rather
# than as a typo.
import subprocess  # noqa: E402

_r = subprocess.run(
    [sys.executable, os.path.join(HERE, "allowlist.py"), "--check"],
    env={**os.environ, "KATA_ALLOWLIST_PROFILE": "sew"},
    capture_output=True,
    text=True,
)
check("an unknown profile refuses to load", _r.returncode != 0 and "unknown profile" in _r.stderr)

print("\npolicy — read-only pinning")
check("GET on a pinned host passes", allowlist.method_allowed("pypi.org", "GET", "/simple/"))
check("POST on a pinned host is refused", not allowlist.method_allowed("pypi.org", "POST", "/simple/"))
check(
    "PUT to storage.googleapis.com is refused (the worst entry on the list)",
    not allowlist.method_allowed("storage.googleapis.com", "PUT", "/bucket/stolen.tar"),
)
check(
    "git fetch is allowed on github.com",
    allowlist.method_allowed("github.com", "POST", "/o/r.git/git-upload-pack"),
)
check(
    "git PUSH is refused on github.com",
    not allowlist.method_allowed("github.com", "POST", "/o/r.git/git-receive-pack"),
)
check(
    "a query string cannot smuggle the allowed suffix",
    not allowlist.method_allowed("github.com", "POST", "/x/git-receive-pack?/git-upload-pack"),
)
# The positive control, and it is the one that would break the sandbox outright:
# a chat completion is a POST, so the provider hosts must stay unpinned.
check(
    "POST to a model API is untouched",
    allowlist.method_allowed("api.anthropic.com", "POST", "/v1/messages"),
)

print("\nenforcement — the addon applies the policy")
f = run("https://huggingface.co/m/config.json")
check("a host outside the profile is 403'd", rejected(f, 403, b"allowlist[swe]"))
check("...and the body names the profile, so the gate can be audited unprivileged", b"[swe]" in f.response.content)
f = run("https://pypi.org/upload", method="POST")
check("a write to a pinned host is 403'd", rejected(f, 403, b"read-only"))
f = run("https://github.com/o/r.git/git-upload-pack", method="POST")
check("git fetch still passes the enforcement point", f.response is None)

print("\ndestination vs claim (the pretty_host bypass)")
# The exact live reproduction, reduced: real destination not on the list, Host
# header claiming one that is. This was ALLOWED and DELIVERED before the fix.
f = run("http://127.0.0.1:18081/exfil", {"Host": "pypi.org"})
check("a spoofed Host does not launder a denied destination", rejected(f, 403, b"host mismatch"))

# The reverse direction matters too, and only the mismatch check catches it:
# both names can live on one IP, so an allowlisted CONNECT target carrying a
# foreign Host is routed by the origin on the header we would have ignored.
f = run("https://github.com/x", {"Host": "attacker.example"})
check("an allowed destination carrying a foreign Host is refused", rejected(f, 403, b"host mismatch"))

# No false positives, or the check gets disabled: a port, odd case and a root
# dot in the Host header are all legitimate and must fold away.
f = run("https://pypi.org/simple/", {"Host": "PyPI.org:443"})
check("port + case in the Host header is not a mismatch", f.response is None)
f = run("https://pypi.org/simple/", {"Host": "pypi.org."})
check("a trailing root dot is not a mismatch", f.response is None)

# HTTP/1.0 clients send no Host at all; judge the destination and move on.
f = _Flow("https://pypi.org/simple/")
f.request.host_header = None
addon.Egress().request(f)
check("a missing Host header is judged on the destination", f.response is None)
f = _Flow("https://evil.example.com/x")
f.request.host_header = None
addon.Egress().request(f)
check("...and a denied destination with no Host is still denied", rejected(f, 403, b"allowlist"))

# The tunnel is gated before an upstream connection exists, not only the
# requests inside it.
check("http_connect denies a host off the list", rejected(run_connect("https://evil.example.com/"), 403, b"allowlist"))
check("http_connect denies a spoofed tunnel", rejected(run_connect("https://evil.example.com/", {"Host": "pypi.org"}), 403, b"host mismatch"))
check("http_connect passes an allowed host", run_connect("https://pypi.org/").response is None)

# The one that turns a bypass into a stolen credential: the swap must never pick
# its provider from the claim. Refused here, and — the real assertion — the
# sentinel is still the sentinel, so nothing was installed on the way out.
f = run("http://127.0.0.1:18081/v1/messages", {"Host": "api.anthropic.com", "x-api-key": "sk-kata"})
check(
    "no key is installed for a claimed provider host",
    rejected(f, 403, b"host mismatch") and f.request.headers["x-api-key"] == "sk-kata",
    str(f.request.headers),
)

print("\nkey swap — the sentinel gate")
f = run("https://openrouter.ai/api/v1/chat/completions", {"Authorization": "Bearer sk-kata"})
check(
    "sentinel bearer is swapped for the real key",
    f.request.headers["Authorization"] == "Bearer sk-or-REAL",
    f.request.headers.get("Authorization", ""),
)

# THE test. An OAuth session token to a host we also know an API key for must
# survive untouched; overwriting it is the expensive silent failure.
f = run("https://api.anthropic.com/v1/messages", {"Authorization": "Bearer oauth-session-token"})
check(
    "OAuth bearer on an API-key host is NOT touched",
    f.request.headers["Authorization"] == "Bearer oauth-session-token"
    and "x-api-key" not in f.request.headers,
    str(f.request.headers),
)

f = run("https://api.anthropic.com/v1/messages", {"x-api-key": "sk-ant-USERS-OWN-KEY"})
check(
    "a real key the user supplied is NOT overwritten",
    f.request.headers["x-api-key"] == "sk-ant-USERS-OWN-KEY",
)

f = run("https://api.anthropic.com/v1/messages")
check(
    "no credential at all means no injection",
    "x-api-key" not in f.request.headers and f.response is None,
)

print("\nkey swap — per-provider credential shapes")
f = run("https://api.anthropic.com/v1/messages", {"x-api-key": "sk-kata"})
check("anthropic x-api-key swapped", f.request.headers["x-api-key"] == "sk-ant-REAL")

f = run("https://generativelanguage.googleapis.com/v1/models", {"x-goog-api-key": "sk-kata"})
check("gemini header swapped", f.request.headers["x-goog-api-key"] == "AIza-REAL")

f = run("https://generativelanguage.googleapis.com/v1/models?key=sk-kata")
check(
    "gemini ?key= query param swapped in place",
    f.request.query["key"] == "AIza-REAL" and "x-goog-api-key" not in f.request.headers,
    str(dict(f.request.query)),
)

print("\nmissing key")
f = run("https://api.openai.com/v1/chat/completions", {"Authorization": "Bearer sk-kata"})
check(
    "sentinel with no host-side key fails 502, does not forward the sentinel",
    f.response is not None
    and f.response.status_code == 502
    and f.request.headers["Authorization"] == "Bearer sk-kata",
    "" if f.response is None else str(f.response.status_code),
)
check(
    "...and the 502 names the fix",
    f.response is not None and b"kata down && kata up" in f.response.content,
)

print("\nlogs leak no values")
joined = "\n".join(_mitm.ctx.log.lines)
check(
    "no real key value appears in any log line",
    not any(v in joined for v in ("sk-or-REAL", "sk-ant-REAL", "AIza-REAL")),
)
check("swaps are logged by env-var name", "KEYSWAP openrouter.ai <- OPENROUTER_API_KEY" in joined)

print()
if FAILS:
    sys.exit(f"{len(FAILS)} failed: {', '.join(FAILS)}")
print("all passed")
