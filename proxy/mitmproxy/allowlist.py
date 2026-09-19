"""Egress policy: which hosts the sandbox may reach, and what it may do to them.

Imported by `addon.py`, which net-up.sh installs into the mitmproxy container
alongside this file. Anything not matched is denied. Runnable on its own as the
audit view — no mitmproxy, no deps:

    python3 proxy/mitmproxy/allowlist.py            # the active profile, annotated
    python3 proxy/mitmproxy/allowlist.py research   # any other profile
    python3 proxy/mitmproxy/allowlist.py --check     # exit non-zero if $KATA_ALLOWLIST_PROFILE is bogus

READ THIS AS AN EXFILTRATION SURFACE. The instinct is to ask "does the agent
need this host" — ingress, a convenience question. The question that matters is
"if the agent turned hostile, what could it *send* here, and who could collect
it", and the answers are wildly unequal: `archive.ubuntu.com` is an anonymous
package feed, while `github.com` is an authenticated write endpoint the agent may
well hold a token for. Order the list by that, not by need.

Three mechanisms, in increasing precision:

1. PROFILES pick which groups of hosts exist at all. One flat union of every
   workflow meant a SWE session that will never touch a model registry still had
   huggingface.co and storage.googleapis.com open. Narrowest that works.

2. Matching is LITERAL, not regex. Every old entry was `^example\\.com$` or
   `^.*\\.example\\.com$` by hand, and two of the ~35 had unescaped dots — in a
   deny-by-default list an unescaped dot silently *widens* the pattern
   (`daily-cloudcode-paXgoogleapis.com` is registerable). A leading dot here
   means "this name and any subdomain of it"; anything else is exact. The class
   of bug is gone rather than fixed.

3. READ_ONLY pins the hosts that have no business receiving a body. It is real
   but partial, and knowing which is important: it removes bulk upload, not the
   channel — a GET can still carry data in the path, a query string or a
   hostname, just slowly and visibly. Treat it as reducing bandwidth and raising
   the noise floor, never as "this host is now safe".

Adding a provider is three edits and all three are load-bearing: a name in
$UPSTREAM_API_KEYS (config.sh, so net-up.sh forwards it), an entry in addon.py's
UPSTREAM_KEYS, and a host in the right group here — the allowlist runs first, so
a host missing from it is 403'd long before the swap is consulted.
"""

from __future__ import annotations

import os

# --- groups ---------------------------------------------------------------
# Named by what they are for, because that is what a profile composes.
GROUPS: dict[str, tuple[str, ...]] = {
    # The OS package feeds. Anonymous, no credential, no write endpoint — the
    # cheapest entries on the list and the only ones every profile gets.
    # NB: apt does not reliably honour HTTP_PROXY; the guest gets an explicit
    # Acquire::http::Proxy in /etc/apt/apt.conf.d/ (see guest/cloud-init).
    "system": (
        ".archive.ubuntu.com",  # regional mirrors are <cc>.archive.ubuntu.com
        "security.ubuntu.com",
        "changelogs.ubuntu.com",
        "esp.ubuntu.com",  # kata-install-cuda
    ),
    # Language registries and source hosting. github.com is the most dangerous
    # entry in this group by a wide margin: an authenticated push is an
    # unlimited, plausible-looking exfiltration channel, which is why it is
    # method-pinned below rather than merely allowed.
    "dev": (
        "pypi.org",
        "files.pythonhosted.org",
        "registry.npmjs.org",
        "nodejs.org",  # headers/source tarballs for node-gyp builds
        ".astral.sh",  # uv installer + the standalone Pythons it fetches
        "github.com",
        "api.github.com",
        "codeload.github.com",
        ".githubusercontent.com",  # raw, objects, avatars
        "codeberg.org",  # a few nvim plugins
    ),
    # The agent CLIs: their OAuth dances and their APIs. Unavoidably powerful —
    # these are the hosts the sandbox is allowed to hold a session for, and a
    # chat completion endpoint accepts arbitrary text by definition. There is no
    # tightening available here beyond "don't include them when you don't need
    # them", which is what the `local` profile is.
    "agents": (
        # Anthropic. Claude Code 2.x moved login to platform.claude.com
        # (superseding console.anthropic.com); the SDK then talks api.anthropic.com.
        "api.anthropic.com",
        "console.anthropic.com",
        "platform.claude.com",
        "claude.ai",
        # OpenAI / Codex CLI: device + browser callback, then the API.
        "auth.openai.com",
        "api.openai.com",
        "chatgpt.com",
        # Google / Gemini CLI. The last four are the eligibility dance, not the
        # API, and they are the reason this group is bigger than it looks.
        "generativelanguage.googleapis.com",
        "oauth2.googleapis.com",
        "accounts.google.com",
        "www.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",  # eligibility check
        "lh3.googleusercontent.com",  # profile picture, required by the above
        "storage.googleapis.com",  # see the READ_ONLY note — worst entry here
        "antigravity-cli-auto-updater-974169037036.us-central1.run.app",
        "openrouter.ai",
        "pi.dev",  # pi's own self-update / extension downloads
    ),
    # Weights and the GPU toolchain. Only for the GPU/research workflow, and the
    # reason profiles are worth having: 3G of CUDA and a model registry with a
    # write API have no place in a SWE session.
    "models": (
        "huggingface.co",
        ".huggingface.co",  # cdn-lfs, cdn-lfs-us-1, …
        "cas-bridge.xethub.hf.co",
        "download.pytorch.org",
        "developer.download.nvidia.com",
    ),
}

# --- profiles -------------------------------------------------------------
# One per workflow at the bottom of README.md. Composed, not copied, so a host
# added to a group lands in every profile that includes it.
PROFILES: dict[str, tuple[str, ...]] = {
    # "Normal SWE": Claude in the guest, cloud or local models, the usual
    # toolchain. The default because it is the common case — and it is already a
    # tightening, since the flat list this replaced included `models` always.
    "swe": ("system", "dev", "agents"),
    # "Research work with remote agents": the above plus the GPU stack.
    # `kata-install-cuda` in a session needs this; `kata build-base -- --cuda`
    # does not, because the provisioning boot runs on plain SLIRP with no gate.
    "research": ("system", "dev", "agents", "models"),
    # "Deepresearch with local agents": llama.cpp, searxng and firecrawl all run
    # on the HOST, reached at $HOST_IP — which NO_PROXY covers, so none of it
    # touches this list. The agent therefore needs apt and nothing else. This is
    # the profile to reach for by default when a session doesn't need the
    # internet: the narrowest one that works is the whole point of the exercise.
    "local": ("system",),
}
DEFAULT_PROFILE = "swe"

# --- what may be done to a host -------------------------------------------
SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})

# host -> path suffixes for which a non-safe method is nevertheless allowed.
# An empty tuple means safe methods only. A host absent from this table is
# unpinned: any method passes.
READ_ONLY: dict[str, tuple[str, ...]] = {
    # Package feeds and binary downloads. A POST here is never a legitimate
    # install; it is someone shipping data out through a host you trusted
    # because it delivers software.
    ".archive.ubuntu.com": (),
    "security.ubuntu.com": (),
    "changelogs.ubuntu.com": (),
    "pypi.org": (),  # uploads go to upload.pypi.org, which is not on the list
    "files.pythonhosted.org": (),
    "registry.npmjs.org": (),  # `npm publish` is a PUT — deliberately dead
    "nodejs.org": (),
    ".astral.sh": (),
    "codeload.github.com": (),
    ".githubusercontent.com": (),
    "download.pytorch.org": (),
    "developer.download.nvidia.com": (),
    "pi.dev": (),
    # Google's eligibility trio. storage.googleapis.com is the single worst
    # entry on the whole allowlist: a fully general object store where
    # `PUT /<bucket>/<object>` uploads arbitrary bytes to a destination the
    # *caller* names. It is here for a config fetch, so pin it to reads; if the
    # Gemini CLI ever needs a write, it will say so in a 403 that names this
    # line, which is a far better outcome than a silent upload endpoint.
    "storage.googleapis.com": (),
    "lh3.googleusercontent.com": (),
    "antigravity-cli-auto-updater-974169037036.us-central1.run.app": (),
    # git over HTTPS: `fetch`/`clone` POST to /git-upload-pack, `push` POSTs to
    # /git-receive-pack. Allowing exactly the first is the gate agreeing with
    # what this project already claims — the agent pushes nowhere, and the only
    # sanctioned way work comes back is `kata project pull` over the local git
    # daemon. Without this pin, a token in the guest makes github.com an
    # unlimited exfiltration channel that looks exactly like normal developer
    # traffic.
    "github.com": ("/git-upload-pack",),
    "codeberg.org": ("/git-upload-pack",),
    # api.github.com is reads-only on purpose too: gists, issues and comments
    # are text-shaped write endpoints, and nothing in the sandbox needs them.
    "api.github.com": (),
}

# --- resolution -----------------------------------------------------------
# Fail closed and fail LOUD on a bogus name: raising here means the addon fails
# to import, mitmproxy never binds, and net-up.sh reports it with the container
# log. A typo must not be able to silently select something permissive — nor
# something empty, which would look like a broken proxy instead of a config
# error.
PROFILE = (os.environ.get("KATA_ALLOWLIST_PROFILE") or "").strip() or DEFAULT_PROFILE
if PROFILE not in PROFILES:
    raise SystemExit(
        f"kata allowlist: unknown profile {PROFILE!r}; "
        f"known profiles: {' '.join(PROFILES)}"
    )


def hosts(profile: str | None = None) -> tuple[str, ...]:
    """Every entry visible in `profile` (default: the active one)."""
    return tuple(h for g in PROFILES[profile or PROFILE] for h in GROUPS[g])


_ACTIVE = frozenset(hosts())


def _match(host: str, entries) -> str | None:
    """The entry matching `host`, or None. One matcher for both tables — two
    would eventually disagree about what `.example.com` means."""
    if host in entries:
        return host
    for e in entries:
        if e[0] == "." and (host.endswith(e) or host == e[1:]):
            return e
    return None


def _norm(host: str) -> str:
    return host.strip().lower().rstrip(".")


def allowed(host: str) -> bool:
    """True iff `host` is in the active profile (deny by default)."""
    return _match(_norm(host), _ACTIVE) is not None


def method_allowed(host: str, method: str, path: str) -> bool:
    """False iff `host` is read-only pinned and this is a write to it."""
    entry = _match(_norm(host), READ_ONLY)
    if entry is None:  # unpinned: any method
        return True
    if method.upper() in SAFE_METHODS:
        return True
    bare = path.partition("?")[0]
    return any(bare.endswith(s) for s in READ_ONLY[entry])


# --- audit view -----------------------------------------------------------
if __name__ == "__main__":
    import sys

    argv = sys.argv[1:]
    if argv and argv[0] == "--check":
        # Importing this module already validated $KATA_ALLOWLIST_PROFILE, so
        # reaching here is the whole answer. net-up.sh calls it with the value
        # it is about to hand the container, which is the thing worth checking.
        print(f"allowlist profile '{PROFILE}' ok ({len(_ACTIVE)} hosts)")
        raise SystemExit(0)

    want = argv[0] if argv else PROFILE
    if want not in PROFILES:
        raise SystemExit(f"unknown profile {want!r}; known: {' '.join(PROFILES)}")
    print(f"profile {want}  ({'active' if want == PROFILE else 'inactive'})")
    for group in PROFILES[want]:
        print(f"\n  [{group}]")
        for h in GROUPS[group]:
            pinned = _match(h, READ_ONLY)
            if pinned is None:
                note = "any method"
            elif READ_ONLY[pinned]:
                note = "read-only + " + " ".join(READ_ONLY[pinned])
            else:
                note = "read-only"
            print(f"    {h:<62} {note}")
    skipped = [g for g in GROUPS if g not in PROFILES[want]]
    if skipped:
        print(f"\n  not in this profile: {' '.join(skipped)}")
