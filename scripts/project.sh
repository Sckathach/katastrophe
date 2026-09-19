#!/usr/bin/env bash
# project.sh — git interchange between you and the agent (kills the chown dance).
#
# Two bare repos per project, both YOURS, served read-only/read-write by the
# git daemon on the bridge (scripts/git-serve.sh). Nothing is shared-writable;
# only git objects cross, and objects are data, never executed.
#
#   you (real repo) --push--> src/<name>.git  ──fetch (ro)──▶ sandbox clone
#                                                                  │ push
#   you (real repo) <--fetch-- src/<name>-agent.git ◀──────────────'
#
# The read/write split is enforced by git itself: only <name>-agent.git has
# daemon.receivepack=true, so a push to <name>.git is refused by the daemon
# ("service not enabled"). That is the core invariant — no hook involved.
#
# Run as YOURSELF (not root). The agent-worktree steps (only needed for the
# filesystem-sharing GPU/container profile) go through `sudo -u $AGENT_USER`
# and are SKIPPED with a notice when there's no agent user or agent-home.
#
# Subcommands:
#   add  <host-repo> [name]   register a repo: create both bare repos, wire
#                             remotes, print the guest commands.
#   push <name>               update ingress from your current branch.
#   pull <name>               fetch the agent's pushes into refs/remotes/agent/*.
#   list                      show registered projects.
#
# Trust invariant: you may READ the agent's branches and merge its git objects;
# never *run* what it produced. `pull` only moves refs — review before merging.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC1091
source "${HERE}/../config.sh"

die() {
  echo "project: $*" >&2
  exit 1
}

ingress_of() { echo "${SHARED_SRC_DIR}/${1}.git"; }
egress_of() { echo "${SHARED_SRC_DIR}/${1}-agent.git"; }

# Run a command as the agent uid from a neutral cwd. `sudo -u agent` inherits
# the caller's cwd; if that's under your 0700 home the agent can't stat it and
# git dies opaquely (same foot-gun as the workspace guard). /tmp is 1777, so the
# agent can always traverse it. The subshell keeps our own cwd unchanged.
as_agent() { (cd /tmp && sudo -u "$AGENT_USER" "$@"); }

# Idempotent `git remote set-url-or-add` in the repo at $1.
ensure_remote() {
  local repo="$1" name="$2" url="$3"
  git -C "$repo" remote set-url "$name" "$url" 2>/dev/null ||
    git -C "$repo" remote add "$name" "$url"
}

require_tools() {
  command -v git >/dev/null || die "install git"
}

# shared-storage must exist, be yours, and be outside your 0700 home (so the
# agent uid can traverse it). It's a §2 subvolume; any you-owned 755 dir works.
preflight_shared() {
  # Refuse an unmounted mountpoint before anything writes to it (config.sh):
  # as root that lands on the root filesystem and vanishes under the next mount.
  require_storage "$SHARED_STORAGE_DIR"
  [[ -d "$SHARED_STORAGE_DIR" ]] ||
    die "shared-storage not found: $SHARED_STORAGE_DIR (set up the §2 storage, or export SHARED_STORAGE_DIR)"
  [[ -O "$SHARED_STORAGE_DIR" ]] ||
    die "you must own $SHARED_STORAGE_DIR (ingress is the trusted→sandbox side)"
  mkdir -p "$SHARED_SRC_DIR" || die "cannot create $SHARED_SRC_DIR"
}

# The agent worktree is only useful on the filesystem-sharing profile (GPU
# container, now deleted). The VM clones over git:// and needs none of this — so its
# absence is a skip with a notice, never a failure.
agent_available() {
  command -v sudo >/dev/null 2>&1 || return 1
  id -u "$AGENT_USER" >/dev/null 2>&1 || return 1
  [[ -d "$MOUNT_HOME" ]] || return 1
}

skip_agent_notice() {
  echo "[=] no agent worktree (need user '$AGENT_USER' + $MOUNT_HOME) — skipping."
  echo "    Not needed: the VM clones over git://."
}

# True iff the egress repo ($2) holds a branch tip the ingress ($1) has never
# seen — i.e. the sandbox actually pushed work. Robust to the ingress moving on
# afterwards, which a plain ref comparison is not.
egress_has_new() {
  local sha ref
  while read -r sha ref; do
    [[ -n "$sha" ]] || continue
    git -C "$1" cat-file -e "${sha}^{commit}" 2>/dev/null || return 0
  done < <(git -C "$2" for-each-ref --format='%(objectname) %(refname)' refs/heads)
  return 1
}

# Guest-side crib sheet. url = ingress (fetch), pushurl = egress (push).
print_guest_commands() {
  local name="$1"
  echo
  echo "    In the sandbox:"
  echo "      git clone git://${HOST_IP}:${GIT_PORT}/${name}.git"
  echo "      cd ${name}"
  echo "      git remote set-url --push origin git://${HOST_IP}:${GIT_PORT}/${name}-agent.git"
  echo "      # then: 'git pull' reads your branches, 'git push' writes the egress repo"
  echo
}

cmd_add() {
  local src="${1:-}" name="${2:-}"
  [[ -n "$src" ]] || die "usage: project add <host-repo> [name]"
  src="$(readlink -f -- "$src")"
  git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $src"
  name="${name:-$(basename "$src")}"
  case "$name" in
  *-agent | *.git) die "reserved name suffix: '$name' (-agent / .git are used for the bare repos)" ;;
  esac

  echo "[*] src ${SHARED_SRC_DIR}"
  preflight_shared

  local ingress egress worktree
  ingress="$(ingress_of "$name")"
  egress="$(egress_of "$name")"
  worktree="${AGENT_WORK_DIR}/${name}"

  [[ -e "$ingress" ]] && die "ingress already exists: $ingress (use 'project push $name')"
  [[ -e "$egress" ]] && die "egress already exists: $egress"
  # Pre-daemon layout: a bare repo with no .git suffix and no export-ok. It is
  # not served, and re-adding under it would be silently ignored. Say so.
  [[ -e "${SHARED_SRC_DIR}/${name}" ]] &&
    die "old-layout ingress at ${SHARED_SRC_DIR}/${name} — the daemon serves <name>.git; move or delete it first"

  echo "[*] ingress (you → sandbox, fetch-only) → $ingress"
  git clone --quiet --bare "$src" "$ingress"
  touch "${ingress}/git-daemon-export-ok"

  # Full object copy, not --shared: alternates would couple the two repos' gc
  # lifetimes (a gc in ingress could prune objects the egress repo still needs).
  # These repos are small; prefer the boring thing.
  echo "[*] egress (sandbox → you, push target) → $egress"
  git clone --quiet --bare "$ingress" "$egress"
  touch "${egress}/git-daemon-export-ok"
  git -C "$egress" config daemon.receivepack true
  git -C "$egress" config receive.maxInputSize "$GIT_MAX_INPUT"
  # Append-only. Your own branches are never at risk (the agent pushes into a
  # SEPARATE repo, and `project pull` only writes refs/remotes/agent/*), so this
  # isn't branch protection — it protects the review trail: without it the agent
  # can rewrite or drop history you have already fetched out and looked at,
  # making a second `project pull` disagree with the first for no visible reason.
  git -C "$egress" config receive.denyDeletes true
  git -C "$egress" config receive.denyNonFastForwards true

  echo "[*] wiring remotes in $src (sandbox→ingress, agent→egress)"
  ensure_remote "$src" sandbox "$ingress"
  ensure_remote "$src" agent "$egress"

  if agent_available; then
    if as_agent mkdir -p "$AGENT_WORK_DIR" 2>/dev/null; then
      if as_agent test -e "$worktree"; then
        echo "[=] agent worktree already exists: $worktree — left alone"
      else
        echo "[*] cloning into the agent's worktree → $worktree"
        as_agent git clone --quiet "$ingress" "$worktree"
        # The agent cannot write $SHARED_SRC_DIR (yours), so its push has to go
        # through the daemon even on the filesystem-sharing profile.
        as_agent git -C "$worktree" remote set-url --push origin \
          "git://${HOST_IP}:${GIT_PORT}/${name}-agent.git"
      fi
    else
      echo "[!] agent cannot write $AGENT_WORK_DIR (is $MOUNT_HOME agent-owned?) — skipping worktree"
    fi
  else
    skip_agent_notice
  fi

  echo "[ok] '$name' registered."
  print_guest_commands "$name"
  echo "    Then: 'project pull $name' brings its pushes into refs/remotes/agent/*."
}

cmd_push() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: project push <name>"
  local repo ingress egress branch worktree
  ingress="$(ingress_of "$name")"
  egress="$(egress_of "$name")"
  worktree="${AGENT_WORK_DIR}/${name}"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this inside your project checkout (cwd is not a git repo)"
  [[ -d "$ingress" ]] || die "no ingress for '$name' — run 'project add' first"

  ensure_remote "$repo" sandbox "$ingress"
  ensure_remote "$repo" agent "$egress"
  branch="$(git -C "$repo" symbolic-ref --short HEAD)" || die "detached HEAD — checkout a branch"

  echo "[*] pushing $branch → ingress ($name)"
  git -C "$repo" push --quiet sandbox "$branch"

  # Fetch (not merge) into the agent worktree if there is one: safe to run while
  # a session is live (refs only), so we never clobber the agent's working tree.
  if agent_available && as_agent test -d "$worktree"; then
    echo "[*] fetching ingress into the agent worktree"
    as_agent git -C "$worktree" fetch --quiet origin
    echo "[ok] agent can now: git -C $worktree merge origin/$branch"
  else
    echo "[ok] in the sandbox: git pull  (origin = git://${HOST_IP}:${GIT_PORT}/${name}.git)"
  fi
}

cmd_pull() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: project pull <name>"
  local repo ingress egress worktree
  ingress="$(ingress_of "$name")"
  egress="$(egress_of "$name")"
  worktree="${AGENT_WORK_DIR}/${name}"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this inside your project checkout (cwd is not a git repo)"
  [[ -d "$egress" ]] || die "no egress repo for '$name' at $egress — run 'project add' first"

  ensure_remote "$repo" agent "$egress"
  echo "[*] fetching egress repo → refs/remotes/agent/*"
  git -C "$repo" fetch --quiet --prune agent '+refs/heads/*:refs/remotes/agent/*'

  # The egress repo starts as a bare clone of the ingress (so the agent's first
  # push is an incremental delta, not a full re-upload that receive.maxInputSize
  # would reject) — so "empty" is never the idle state, and we can't just look
  # for refs. "The agent pushed something" == the egress holds a commit the
  # ingress doesn't. Say it explicitly: otherwise "nothing pushed yet" and "pull
  # is broken" look identical.
  if ! egress_has_new "$ingress" "$egress"; then
    echo "[=] no commits in the egress repo that the ingress lacks — nothing pushed yet."
    echo "    In the sandbox: git push origin <branch>  (pushurl = ${name}-agent.git)"
    if agent_available && as_agent test -d "$worktree"; then
      echo "    (an agent worktree exists at $worktree — it must push too, not just commit)"
    fi
    return 0
  fi
  echo "[ok] review before merging (never run agent artifacts): git -C $repo log --oneline agent/<branch>"
}

cmd_list() {
  # Projects live on whichever tree the storage mode picked, and `kata git up`
  # serves exactly one of them. Print it, so a `project add` that landed on the
  # local tree can't look like a project that vanished.
  echo "[*] src ${SHARED_SRC_DIR}"
  [[ -d "$SHARED_SRC_DIR" ]] || {
    echo "no projects (no $SHARED_SRC_DIR yet)"
    return 0
  }
  local p name egress heads
  for p in "$SHARED_SRC_DIR"/*.git; do
    [[ -d "$p" ]] || continue
    name="$(basename "$p" .git)"
    [[ "$name" == *-agent ]] && continue # the egress half, listed with its project
    if [[ ! -e "${p}/git-daemon-export-ok" ]]; then
      echo "  $name  (not served — no git-daemon-export-ok; not ours)"
      continue
    fi
    egress="$(egress_of "$name")"
    if [[ -d "$egress" ]]; then
      heads="$(git -C "$egress" for-each-ref --format='%(refname:short)' refs/heads | paste -sd, -)"
      echo "  $name  (ingress + egress; agent branches: ${heads:-none})"
    else
      echo "  $name  (ingress only — no egress repo, re-run 'project add')"
    fi
  done
}

[[ $EUID -ne 0 ]] || die "run as yourself, not root (agent steps self-sudo)"
require_tools

sub="${1:-}"
shift || true
case "$sub" in
add) cmd_add "$@" ;;
push) cmd_push "$@" ;;
pull) cmd_pull "$@" ;;
list) cmd_list "$@" ;;
-h | --help | "")
  echo "usage: project {add <host-repo> [name] | push <name> | pull <name> | list}"
  exit 1
  ;;
*) die "unknown subcommand: $sub" ;;
esac
