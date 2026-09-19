# THE RULE: `sudo` silently eats your exported variables

*(Promoted from a single instance to a rule 2026-09-13, because it has now bitten
this project twice in two unrelated places and both times it read as a bug in
something else.)*

> **Anything you `export` in your shell is GONE by the time a `sudo`'d script
> reads it.** sudo's `env_reset` strips the environment before the command
> starts. Nothing errors. The variable is simply empty, and whatever depended on
> it fails later, somewhere else, for a reason that names the wrong thing.

This is nastier than a normal bug because the *setup* looks like it worked. The
container comes up. The script exits 0. You find out at the first real request.

The two times it landed here:

1. **Upstream API keys** (below). `kata up` runs `sudo net-up.sh` with no `-E`,
   so `$ANTHROPIC_API_KEY` & co. never arrived. Symptom: proxy healthy, first
   provider call 401. Went unnoticed for months because no upstream was wired.
2. **`KATA_STORAGE`** — the storage mode, deleted 2026-09-13, so nothing is
   passed through the environment any more. The lesson outlived it: the CLI had to
   use `sudo env KATA_STORAGE=… script`, *not* `Command::env` (sudo drops it) and
   *not* `sudo -E` (depends on the host's sudoers `setenv` policy, so it works on
   your machine and not on someone else's). `env` is just a binary the elevated
   shell execs, so no policy is involved. Keep that shape if you ever need to pass
   a non-secret down again.

**Corollary found 2026-09-13: `sudo` inside an already-root process rewrites
`SUDO_USER` to `root`.** So `$HOST_USER`, which every script derives from
`SUDO_USER`, silently becomes `root` — and the failure surfaces somewhere else
entirely. In `tests/guards.sh` it came out as `require_storage` refusing a temp
bases dir with *"owned by 'sckathach', expected 'root'"*, several layers away from
the nested `sudo env` that caused it. Where it would matter in the real code:
anything re-sudoing from a root context loses the invoking user, and that is
exactly who `save_base` must chown a freshly baked base back to. If you are
already root, call the script directly and pass what it needs
(`env HOST_USER=… script`); `vm-supervise.sh` exports `HOST_USER` for the same
reason — a detached process has no `SUDO_USER` at all.

**The two fixes, and when each applies:**

| the value is | put it |
|---|---|
| a **secret** | in a root-owned `0600` file the script reads |
| not a secret | on the command line: `sudo env VAR=… script` |

Never `sudo -E` as the fix. It is policy-dependent, so it makes the bug
*machine-specific* rather than fixing it.
