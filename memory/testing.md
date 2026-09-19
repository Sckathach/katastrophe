# Tests: the invariants, executable

The suites themselves are documented in their own headers (`tests/lib.sh` is the
whole framework and fits on a screen). This is the design reasoning behind them —
the rules that were each earned by a test that passed while proving nothing.

Five suites, one runner. `kata test` is `tests/run.sh`; run it unprivileged for
the fast half, under `sudo` for the launch guards.

| suite | what | needs |
| --- | --- | --- |
| `tests/unit.sh` | pure functions in `lib.sh` (base metadata, storage ownership, `state_field`) + the config-override contract | nothing, <1s |
| `tests/guards.sh` | the real launch refusals in `vm.sh`, plus `net-up.sh` arg validation (N1) | root; **skips** politely without it |
| `tests/gate.sh` | the egress gate **as deployed** (D0–D9: destination vs `Host:`, non-arrival, read-only pins, the deployed profile's own boundary) | a running proxy (`kata up`); no privilege |
| `proxy/mitmproxy/test_addon.py` | the policy (profiles, literal matching, read-only) + the gate judges the destination + the swap fires **iff** the sentinel was presented | python3 only (mitmproxy is stubbed) |
| `bash -n` over every script | a suite that passes while a script can't parse is worse than useless | nothing |

**Stubbed and deployed are not substitutes**, and the `Host:`-header bug is the
proof: `test_addon.py` is the only place the stolen-key case can be shown (the
stub holds a fake key; this host holds none), and `gate.sh` is the only thing
that can tell you `/etc/agent-proxy/addon.py` is the file in the repo and that
the container was restarted after you edited it.

**`scripts/audit-egress.sh` is deliberately NOT in the runner.** T1–T4 (no DNS,
no direct TCP, no raw sockets, proxy reachable) can only be proven from the
agent's vantage point — the host cannot answer them on the guest's behalf.
`kata ssh`, then run it inside.

Things that are load-bearing about the harness (`tests/lib.sh`, ~120 lines, no
bats — it is a few thousand lines of bash plus a submodule to provide `@test`
blocks for a project whose thesis is that less code is a security feature):

- **Tests are named after the invariant, not the function.** `T`/`G`/`S` are the
  IDs from the old (deleted) security-invariants table; `E` (egress
  preflight), `B` (base integrity) and `W` (storage/foot-guns) are new. That doc
  was a table of ~40 invariants that were **never executable**, which is why it
  rotted. The table is gone; the IDs survive here, running. What genuinely
  cannot run from the host is `tests/MANUAL.md`, labelled as manual rather than
  counted as coverage.
- **`deny` requires a message pattern, not just a non-zero exit.** A refusal test
  that only checks the status passes when the script dies for an unrelated
  reason: `vm.sh --from c --to c` exits 1 whether it refused a stale bake or
  simply couldn't find the base, and the second one silently stops testing the
  guard. The pattern pins the failure to the invariant.
- **Every denial section carries a positive control.** `deny` passing on a host
  where the thing under test isn't running proves nothing. `E5` asserts the live
  gate really answers 403; without it, every `E*` could be green because `vm.sh`
  refuses everything here.
- **`permits` is the third verb**, for "the command may fail, but NOT for this
  reason" — the `--ro`-under-your-home exemption is a *tested decision* rather
  than a comment. Those tests are stopped by a **later** refusal on purpose
  (`PROXY_PORT=9`), which is why the base-sanity block sits **before** the egress
  preflight in `vm.sh`: with the old order the stopper fired first and the test
  passed without ever reaching the check.
- **A failed guard test must not be able to boot a VM**, and this is enforced,
  not hoped for: `vm()` injects the stopper unless the test sets `PROXY_PORT`
  itself, plus `timeout 60` (which can't wrap a shell function, hence its
  position). The lesson: **if the assertion is "X is refused", then the failure
  mode of the test is doing X.** Here W2 passed `--rw $HOME` — and `$HOME` inside
  a sudo'd script is `/root`, while `FORBIDDEN_WORKSPACE_PREFIX` is
  `/home/<you>`, so nothing matched, nothing refused, and it booted a guest with
  root's home writable at `/mnt/rw_1`. It presented as a hang. Ask the code which
  prefix it defends (`$FORBIDDEN_WORKSPACE_PREFIX`) instead of assuming.
- **A negative assertion needs proof the code path ran** — `permits` therefore
  takes a second pattern, a *reached-marker* matching the stopper's own message.
  Earned the hard way on the first root run: two `permits` tests reported PASS
  while dying at an unrelated storage error, having never reached the guard. An
  absent message is not evidence of anything unless you know you got there. Any
  test asserting an absence needs the same treatment.
- **The guards are faked with `sudo env VAR=…`**, one constant per test, which
  doubles as a live demo of THE RULE — `sudo VAR=… script` would be stripped by
  `env_reset`, and then every test passes for the wrong reason.
- **E2 (missing `agent_vm` table) is an honest `skip`.** Faking it means tearing
  down the live gate, and a test that breaks your network to make a point is a
  test you disable. `skip` exists so that reads as *not checked here* rather than
  as green.

## Refusals have one shape (`gate`/`refuse` in `lib.sh`)

```
error: <one line: what is wrong>
  <indented detail: what would happen if we continued>
  fix: <the command>
```

cargo/rustc/git's convention, and it earns its keep for boring reasons: the
summary is greppable (which is what `deny` matches on), and it goes to **stderr**
— the hand-rolled `echo` blocks it replaced went to stdout, so a refusal was
indistinguishable from output. `gate <force> <summary>` handles the `--force`
case too, so a guard is one call site instead of an if/else with the body written
twice; keep the summary force-neutral, since `gate` prefixes it with
`error:`/`warning:`. Body comes from a heredoc, and the `[[ ! -t 0 ]]` test in
there is load-bearing: without it a caller that forgets the heredoc blocks
forever reading the terminal, which looks exactly like a hang in qemu.
