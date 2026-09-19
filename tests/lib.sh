# tests/lib.sh — the whole test framework, and it is on purpose that it fits on
# one screen.
#
# No bats: it is a few thousand lines of bash plus a git submodule, to provide
# `@test` blocks and TAP output for a project whose entire point is that less
# code is a security feature. A test here is a command and an expected outcome.
#
# THE VOCABULARY IS THE POINT. Tests are named after the invariant they defend
# (T1, G4, B2 …), not after the function they call, and the two verbs are the
# two directions a security check can be wrong:
#
#   allow   <id> <desc> -- cmd…            must SUCCEED  (positive control)
#   deny    <id> <desc> <pattern> -- cmd…  must FAIL, and say why
#   permits <id> <desc> <pattern> <reached> -- cmd…
#                                          may fail, but NOT for that reason —
#                                          and <reached> proves it got that far
#   says    <id> <desc> <pattern> -- cmd…  must print this; status ignored
#   is      <id> <desc> <want> <got>       a property, not a command outcome
#   skip    <id> <desc> <why>              honestly not checked here
#
# `deny` requires a pattern for a reason worth internalising: **a refusal test
# that only checks the exit status passes when the script dies for an unrelated
# reason.** `sudo vm.sh --from c --to c` exits 1 whether it refused a stale bake
# or simply could not find the base — and the second one silently stops testing
# the guard. The pattern is what pins the failure to the invariant.
#
# A positive control is not optional either. `deny` passing on a host where the
# thing under test isn't even installed is not evidence of anything; every
# section here pairs its denials with at least one `allow`.
set -uo pipefail

T_PASS=0 T_FAIL=0 T_SKIP=0
T_FAILED_IDS=()

if [[ -t 1 ]]; then
  _G=$'\033[32m' _R=$'\033[31m' _Y=$'\033[33m' _D=$'\033[2m' _O=$'\033[0m'
else
  _G="" _R="" _Y="" _D="" _O=""
fi

_pass() {
  printf '  %s[PASS]%s %-4s %s\n' "$_G" "$_O" "$1" "$2"
  T_PASS=$((T_PASS + 1))
}
_fail() {
  printf '  %s[FAIL]%s %-4s %s\n' "$_R" "$_O" "$1" "$2"
  if [[ -n "${3:-}" ]]; then printf '         %s%s%s\n' "$_D" "$3" "$_O"; fi
  T_FAIL=$((T_FAIL + 1))
  T_FAILED_IDS+=("$1")
}
skip() { # skip <id> <desc> <why>
  printf '  %s[SKIP]%s %-4s %s %s(%s)%s\n' "$_Y" "$_O" "$1" "$2" "$_D" "${3:-}" "$_O"
  T_SKIP=$((T_SKIP + 1))
}

section() { printf '\n%s\n' "$1"; }

# Split "id desc [pattern] -- cmd…" and run the command with output captured.
# Output is merged (2>&1) deliberately: a test asserting on a message must not
# depend on which stream the script chose, and several of these scripts are
# mid-migration from stdout to stderr.
_run_after_dashdash() {
  local -n _out="$1" _rc="$2"
  shift 2
  local cmd=()
  while (($#)); do
    if [[ "$1" == "--" ]]; then
      shift
      cmd=("$@")
      break
    fi
    shift
  done
  # stdin from /dev/null: a command under test must never be able to block on
  # input. A refusal helper that forgets its heredoc would otherwise read the
  # terminal forever, which is indistinguishable from a hung VM.
  _out="$("${cmd[@]}" </dev/null 2>&1)"
  _rc=$?
  return 0
}

allow() { # allow <id> <desc> -- cmd…
  local id="$1" desc="$2" out rc
  _run_after_dashdash out rc "$@"
  if ((rc == 0)); then
    _pass "$id" "$desc"
  else
    _fail "$id" "$desc" "exited ${rc}: $(head -2 <<<"$out" | tr '\n' ' ')"
  fi
}

deny() { # deny <id> <desc> <pattern> -- cmd…
  local id="$1" desc="$2" pat="$3" out rc
  _run_after_dashdash out rc "$@"
  if ((rc == 0)); then
    _fail "$id" "$desc" "command SUCCEEDED; it was supposed to be refused"
  elif ! grep -qiE "$pat" <<<"$out"; then
    _fail "$id" "$desc" "refused (rc=${rc}) but not for the expected reason; wanted /${pat}/, got: $(head -2 <<<"$out" | tr '\n' ' ')"
  else
    _pass "$id" "$desc"
  fi
}

# The command may well fail — but NOT for this reason. For "the guard under test
# did not fire", where letting the command run to completion would do something
# you don't want in a test (like booting a VM), so it is stopped by a *later*
# refusal on purpose. Pairs with `deny` to make an exemption a tested decision
# rather than a comment: --rw under your home is denied, --ro is permitted.
#
# THE SECOND PATTERN IS NOT OPTIONAL, and this is the lesson that earned it: a
# negative assertion passes when the forbidden message is absent — INCLUDING when
# the command died long before the check could run. The first version of this
# verb reported PASS for two tests that exited at an unrelated storage error and
# never reached the guard at all. So `reached` must match something printed by
# the stopper DOWNSTREAM of the check: proof the code path executed. Any test
# that asserts an absence needs the same thing.
permits() { # permits <id> <desc> <must-NOT-appear> <reached-marker> -- cmd…
  local id="$1" desc="$2" pat="$3" reached="$4" out rc
  _run_after_dashdash out rc "$@"
  if grep -qiE "$pat" <<<"$out"; then
    _fail "$id" "$desc" "output matched /${pat}/, i.e. it WAS refused for that reason"
  elif ! grep -qiE "$reached" <<<"$out"; then
    _fail "$id" "$desc" "VACUOUS: never reached the check (no /${reached}/); got: $(head -2 <<<"$out" | tr '\n' ' ')"
  else
    _pass "$id" "$desc"
  fi
}

# Output must match; exit status ignored. For asserting on what a --force path
# tells you, where the command is expected to proceed and fail later.
says() { # says <id> <desc> <pattern> -- cmd…
  local id="$1" desc="$2" pat="$3" out rc
  _run_after_dashdash out rc "$@"
  if grep -qiE "$pat" <<<"$out"; then
    _pass "$id" "$desc"
  else
    _fail "$id" "$desc" "wanted /${pat}/, got: $(head -3 <<<"$out" | tr '\n' ' ')"
  fi
}

# Assert a captured value, for invariants that are a property rather than a
# command outcome (ownership, a mode, a bound address).
is() { # is <id> <desc> <expected> <actual>
  if [[ "$3" == "$4" ]]; then
    _pass "$1" "$2"
  else
    _fail "$1" "$2" "expected '${3}', got '${4}'"
  fi
}

report() { # -> exit status for the script
  printf '\n  %d passed, %d failed, %d skipped\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
  if ((T_FAIL)); then
    printf '  failed: %s\n' "${T_FAILED_IDS[*]}"
    return 1
  fi
  return 0
}
