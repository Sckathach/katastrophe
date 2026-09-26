#!/usr/bin/env bash
# project.sh — git interchange between you and the agent (`kata project`).
#
# Two bare repos per project, both yours, served by the git daemon on the bridge
# (git-serve.sh). Nothing is shared-writable; only git objects cross.
#
#   you (real repo) --push--> src/<name>.git  ──fetch (ro)──▶ sandbox clone
#                                                                  │ push
#   you (real repo) <--fetch-- src/<name>-agent.git ◀──────────────'
#
# Only <name>-agent.git has daemon.receivepack=true, so git itself refuses a push
# to <name>.git. Runs as you; needs no privilege.
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

# Idempotent `git remote set-url-or-add` in the repo at $1.
ensure_remote() {
  local repo="$1" name="$2" url="$3"
  git -C "$repo" remote set-url "$name" "$url" 2>/dev/null ||
    git -C "$repo" remote add "$name" "$url"
}

require_tools() {
  command -v git >/dev/null || die "install git"
}

# Must exist, be yours, and sit outside your 0700 home.
preflight_shared() {
  require_storage "$SHARED_STORAGE_DIR"
  [[ -d "$SHARED_STORAGE_DIR" ]] ||
    die "shared-storage not found: $SHARED_STORAGE_DIR (set up the §2 storage, or export SHARED_STORAGE_DIR)"
  [[ -O "$SHARED_STORAGE_DIR" ]] ||
    die "you must own $SHARED_STORAGE_DIR (ingress is the trusted→sandbox side)"
  mkdir -p "$SHARED_SRC_DIR" || die "cannot create $SHARED_SRC_DIR"
}

# True iff egress ($2) holds a branch tip ingress ($1) has never seen: the
# sandbox pushed work. Unlike a ref comparison, robust to ingress moving on.
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

  local ingress egress
  ingress="$(ingress_of "$name")"
  egress="$(egress_of "$name")"

  [[ -e "$ingress" ]] && die "ingress already exists: $ingress (use 'project push $name')"
  [[ -e "$egress" ]] && die "egress already exists: $egress"
  # Old layout (no .git suffix): not served, and silently shadowing a re-add.
  [[ -e "${SHARED_SRC_DIR}/${name}" ]] &&
    die "old-layout ingress at ${SHARED_SRC_DIR}/${name} — the daemon serves <name>.git; move or delete it first"

  echo "[*] ingress (you → sandbox, fetch-only) → $ingress"
  git clone --quiet --bare "$src" "$ingress"
  touch "${ingress}/git-daemon-export-ok"

  # Full copy, not --shared: alternates would let an ingress gc prune egress objects.
  echo "[*] egress (sandbox → you, push target) → $egress"
  git clone --quiet --bare "$ingress" "$egress"
  touch "${egress}/git-daemon-export-ok"
  git -C "$egress" config daemon.receivepack true
  git -C "$egress" config receive.maxInputSize "$GIT_MAX_INPUT"
  # Append-only, to protect the review trail: the agent cannot rewrite or drop
  # history you already fetched and looked at.
  git -C "$egress" config receive.denyDeletes true
  git -C "$egress" config receive.denyNonFastForwards true

  echo "[*] wiring remotes in $src (sandbox→ingress, agent→egress)"
  ensure_remote "$src" sandbox "$ingress"
  ensure_remote "$src" agent "$egress"

  echo "[ok] '$name' registered."
  print_guest_commands "$name"
  echo "    Then: 'project pull $name' brings its pushes into refs/remotes/agent/*."
}

cmd_push() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: project push <name>"
  local repo ingress egress branch
  ingress="$(ingress_of "$name")"
  egress="$(egress_of "$name")"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this inside your project checkout (cwd is not a git repo)"
  [[ -d "$ingress" ]] || die "no ingress for '$name' — run 'project add' first"

  ensure_remote "$repo" sandbox "$ingress"
  ensure_remote "$repo" agent "$egress"
  branch="$(git -C "$repo" symbolic-ref --short HEAD)" || die "detached HEAD — checkout a branch"

  echo "[*] pushing $branch → ingress ($name)"
  git -C "$repo" push --quiet sandbox "$branch"

  echo "[ok] in the sandbox: git pull  (origin = git://${HOST_IP}:${GIT_PORT}/${name}.git)"
}

cmd_pull() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: project pull <name>"
  local repo ingress egress
  ingress="$(ingress_of "$name")"
  egress="$(egress_of "$name")"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "run this inside your project checkout (cwd is not a git repo)"
  [[ -d "$egress" ]] || die "no egress repo for '$name' at $egress — run 'project add' first"

  ensure_remote "$repo" agent "$egress"
  echo "[*] fetching egress repo → refs/remotes/agent/*"
  git -C "$repo" fetch --quiet --prune agent '+refs/heads/*:refs/remotes/agent/*'

  # Egress starts as a clone of ingress, so it is never empty: "pushed" means it
  # holds a commit ingress lacks. Said out loud, or "nothing yet" looks broken.
  if ! egress_has_new "$ingress" "$egress"; then
    echo "[=] no commits in the egress repo that the ingress lacks — nothing pushed yet."
    echo "    In the sandbox: git push origin <branch>  (pushurl = ${name}-agent.git)"
    return 0
  fi
  echo "[ok] review before merging (never run agent artifacts): git -C $repo log --oneline agent/<branch>"
}

cmd_list() {
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

[[ $EUID -ne 0 ]] || die "run as yourself, not root"
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
