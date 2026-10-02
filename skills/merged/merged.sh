#!/usr/bin/env bash
#
# merged.sh — post-merge cleanup for the /merged skill, one or more repos.
#
# For each repo (default: git toplevel of cwd):
#   1. cleanup: switch to the default branch, fetch --prune, pull --ff-only, and
#      delete the merged feature branch. A branch is only deleted when GitHub
#      reports its PR MERGED; otherwise STOP for that repo (nothing deleted).
#      Already on the default branch -> just fetch + pull.
#   2. cross-box sync: ALWAYS run sync-box.sh (sibling of this file) after a
#      successful cleanup, including the already-on-default case. Whether a repo
#      is a box repo is decided only by sync-box.sh, never by the caller.
#
# Usage:  merged.sh [<repo-dir>...]
# Prints per-repo RESULT:/STOP: lines and a final SUMMARY line. Exits non-zero if
# any repo hit a STOP.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$HERE/sync-box.sh"

[ $# -gt 0 ] || set -- "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

cleanup() { # run in the repo dir; prints RESULT:/STOP:, returns 1 on STOP
  local default current state
  default=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^refs/remotes/origin/##')
  [ -n "${default:-}" ] || default=$(gh repo view --json defaultBranchRef \
    -q .defaultBranchRef.name 2>/dev/null)
  [ -n "${default:-}" ] || { echo "STOP: cannot determine the default branch"; return 1; }
  current=$(git branch --show-current)

  if [ "$current" = "$default" ]; then
    git fetch --prune -q && git pull --ff-only -q \
      || { echo "STOP: fetch/pull on $default failed"; return 1; }
    echo "RESULT: already on $default, pulled; nothing to clean"
    return 0
  fi

  # Merge gate — never delete unmerged local work.
  state=$(gh pr view "$current" --json state -q .state 2>/dev/null || echo NONE)
  if [ "$state" != "MERGED" ]; then
    echo "STOP: PR for '$current' is '$state' (need MERGED). Not deleting."
    return 1
  fi

  # -D (not -d): the merge is gated via GitHub above, and -d would wrongly
  # refuse after a squash merge. --prune drops the auto-deleted remote ref.
  git switch -q "$default" && git fetch --prune -q && git pull --ff-only -q \
    || { echo "STOP: could not switch to / pull $default"; return 1; }
  git branch -D "$current" >/dev/null || { echo "STOP: could not delete '$current'"; return 1; }
  echo "RESULT: merged '$current' cleaned; now on $default, up to date"
}

stops=0
for repo in "$@"; do
  dir="$(cd "$repo" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "== $repo"; echo "STOP: not a git repo"; stops=$((stops+1)); continue; }
  echo "== $(basename "$dir")"
  if ! (cd "$dir" && cleanup); then
    echo "(cross-box sync skipped: cleanup stopped)"
    stops=$((stops+1))
    continue
  fi
  "$SYNC" "$dir" || stops=$((stops+1))
done

if [ "$stops" -gt 0 ]; then
  echo "SUMMARY: $stops STOP(s) across $# repo(s); see the STOP lines above."
  exit 1
fi
echo "SUMMARY: all $# repo(s) cleaned and synced."
