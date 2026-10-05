#!/usr/bin/env bash
#
# sync-box.sh — cross-box sync for the /merged skill.
#
# After /merged cleans a box repo locally, the same change must land on every
# OTHER box that repo deploys to (sibling clones under /srv/dev/repos). For each
# such box this script, over SSH:
#   1. checks the clone is safe to deploy into: it exists, is on its DEFAULT
#      branch (origin/HEAD), has no tracked changes, and (WRF pipeline repos) no
#      wrf-orchestrator@ run is active. Any failure is a STOP: nothing is touched.
#      Submodules listed in repo_submodules are exempt from the tracked-changes
#      check when only their POINTER drifted (the submodule's own worktree is
#      clean and its checked-out commit is on a remote ref) — a stale submodule
#      checkout, not local work.
#   2. fast-forwards the default branch (`pull --ff-only`), then checks out the
#      repo_submodules at the commits the new HEAD records.
#   3. syncs the repo's Python venv when it has one (`.venv` + requirements.txt),
#      since a new requirement otherwise silently degrades the service.
#   4. on the SERVER runs the repo's install command, if it has one. On the
#      workstation (ethan-debian) install is never auto-run — left to Ethan.
#
# Usage:  sync-box.sh [<repo>] [--dry-run]
#   <repo>     path or name of the merged repo (default: git toplevel of cwd).
#   --dry-run  run the step-1 checks on each other box, print the plan; change nothing.
#   --list-submodules  print the repo's repo_submodules paths and exit (merged.sh
#              uses this to keep the same submodules current on THIS box).
#
# Data-driven: the case tables below (repo -> boxes, box -> ssh host,
# repo -> install command, repo -> pipeline guard, repo -> submodules) are the
# whole policy. Prints
# one RESULT:/STOP: line to read off. Exits non-zero only on STOP.
#
# SSH direction: workstation -> server works via the `home-server` alias in
# ~/.ssh/config. server -> workstation ("ethan-debian") needs the server to have
# its own SSH key + host resolution, which is not set up today. So when running
# ON the server, we do NOT try to SSH the workstation — we print a reminder with
# the exact commands Ethan must run there, and finish without a STOP.
set -euo pipefail

REPO=""
DRY=0
LIST_SUBS=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --list-submodules) LIST_SUBS=1 ;;
    *) REPO="$a" ;;
  esac
done
if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || REPO="$(pwd)"
fi
# Normalize a directory path to a repo NAME (/srv/dev/repos/<name> -> <name>).
if [ -d "$REPO" ]; then
  REPO="$(basename "$(cd "$REPO" && pwd)")"
fi

# --- current box, from hostname ---
case "$(hostname)" in
  ethan-debian) THIS=workstation ;;
  home-server)  THIS=server ;;
  *) echo "RESULT: no-sync (unknown hostname '$(hostname)')"; exit 0 ;;
esac

# --- policy tables ---
repo_boxes() {   # repo name -> boxes it deploys to (space-separated)
  case "$1" in
    # Config repos (each has its own install.sh).
    dev-env)                          echo "workstation server" ;;
    my-system)                        echo "workstation" ;;
    home-server)                      echo "server" ;;
    valheim-server)                   echo "server" ;;
    # Project repos: server-side services (data on /srv/dev/wrf), orchestrated by
    # home-server's hs-*/wrf-orchestrator@ systemd units. No install.sh of their own
    # — the deploy is the git pull (+ venv sync); the units run the fresh code on
    # their next tick.
    steam-price-tracker)              echo "server" ;;
    WRFrontiersDB-Data)               echo "server" ;;
    WRFrontiersDB-Orchestrator)       echo "server" ;;
    WRFrontiersDB-Parser)             echo "server" ;;
    WRFrontiersDB-Site)               echo "server" ;;
    WRFrontiers-Exporter)             echo "server" ;;
    WRFrontiers-News-Scraper)         echo "server" ;;
    WRFrontiers-Discount-Visualizer)  echo "server" ;;
    WRF-Compat-Tools)                 echo "server" ;;
    *)                                echo "" ;;
  esac
}
box_host() {     # box -> ssh host that reaches it
  case "$1" in
    workstation) echo "ethan-debian" ;;
    server)      echo "home-server" ;;
  esac
}
repo_install() { # repo name -> install command (server form; host repos need root).
                 # Empty = no installer (the pull + venv sync is the deploy).
  case "$1" in
    dev-env)        echo "/srv/dev/repos/dev-env/install.sh" ;;
    my-system)      echo "/srv/dev/repos/my-system/users/install.sh" ;;
    home-server)    echo "sudo -n /srv/dev/repos/home-server/install.sh" ;;
    valheim-server) echo "sudo -n /srv/dev/repos/valheim-server/install.sh" ;;
    *)              echo "" ;;
  esac
}
repo_pipeline() { # repo name -> 1 if wrf-orchestrator@ runs its checkout (don't pull mid-run)
  case "$1" in
    WRFrontiersDB-Orchestrator|WRFrontiersDB-Parser|WRFrontiersDB-Site|WRFrontiersDB-Data|WRFrontiers-Exporter) echo 1 ;;
    *) echo 0 ;;
  esac
}

repo_submodules() { # repo name -> submodule paths to keep at the recorded commit
                    # (space-separated). Both vendor WRFrontiersDB-Design.
  case "$1" in
    WRFrontiersDB-Site)               echo "vendor/wrf-design" ;;
    WRFrontiers-Discount-Visualizer)  echo "src/frontend/vendor/wrf-design" ;;
    *)                                echo "" ;;
  esac
}

if [ "$LIST_SUBS" = 1 ]; then
  repo_submodules "$REPO"
  exit 0
fi

BOXES="$(repo_boxes "$REPO")"
if [ -z "$BOXES" ]; then
  echo "RESULT: no-sync ($REPO is not a box repo)"
  exit 0
fi

# Runs ON the target box (bash -s). Args: repo, mode (check|deploy), pipeline (0|1),
# submodules (space-separated paths, may be empty).
# Prints "ok: ..." lines; on a failed check prints "STOP: ..." and exits 3.
# shellcheck disable=SC2016
REMOTE='
set -uo pipefail
repo="$1"; mode="$2"; pipeline="$3"; subs="${4:-}"
d="/srv/dev/repos/$repo"
stop() { echo "STOP: $*"; exit 3; }
[ -d "$d/.git" ] || [ -f "$d/.git" ] || stop "$d is not a git clone on $(hostname)"
git -C "$d" fetch --prune -q origin || stop "git fetch failed in $d"
def=$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed "s#^origin/##")
if [ -z "$def" ]; then
  git -C "$d" remote set-head origin --auto >/dev/null 2>&1 || true
  def=$(git -C "$d" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed "s#^origin/##")
fi
[ -n "$def" ] || stop "cannot determine the default branch of $d"
cur=$(git -C "$d" branch --show-current)
[ "$cur" = "$def" ] || stop "$d is on \"${cur:-detached HEAD}\", not its default branch \"$def\"; the merge would not be deployed. Not touching it."
dirty=$(git -C "$d" status --porcelain --untracked-files=no)
drifted=""
for p in $subs; do
  echo "$dirty" | grep -qxF " M $p" || continue
  sd="$d/$p"
  [ -z "$(git -C "$sd" status --porcelain --untracked-files=no)" ] \
    || stop "$sd has uncommitted tracked changes inside the submodule; not touching it"
  [ -n "$(git -C "$sd" branch -r --contains HEAD 2>/dev/null)" ] \
    || stop "$sd is checked out at $(git -C "$sd" rev-parse --short HEAD), which is on no remote branch (local submodule work?); not touching it"
  dirty=$(echo "$dirty" | grep -vxF " M $p" || true)
  drifted="$drifted $p"
done
[ -z "$dirty" ] || stop "$d has uncommitted tracked changes; not touching it: $(echo "$dirty" | head -3 | tr "\n" " ")"
if [ "$pipeline" = 1 ]; then
  active=$(systemctl list-units "wrf-orchestrator@*" --state=activating,active --no-legend 2>/dev/null | awk "{print \$1}" | tr "\n" " ")
  [ -z "$active" ] || stop "a WRF pipeline run is active ($active); pulling now would change code mid-run. Re-run after it finishes."
fi
behind=$(git -C "$d" rev-list --count "HEAD..origin/$def")
venv=0; [ -x "$d/.venv/bin/pip" ] && [ -f "$d/requirements.txt" ] && venv=1
if [ "$mode" = check ]; then
  echo "ok: $d on $def, clean, $behind commit(s) behind origin/$def$([ "$venv" = 1 ] && echo ", venv to sync")${drifted:+, submodule pointer drift to reset:$drifted}"
  exit 0
fi
git -C "$d" pull --ff-only -q || stop "pull --ff-only failed in $d"
echo "ok: pulled $d to $(git -C "$d" log -1 --format=%h) ($behind new commit(s))"
if [ -n "$subs" ]; then
  # shellcheck disable=SC2086
  git -C "$d" submodule update --init -q -- $subs || stop "pulled $d but submodule update failed ($subs)"
  echo "ok: submodules at recorded commits:$(for p in $subs; do printf " %s@%s" "$p" "$(git -C "$d/$p" rev-parse --short HEAD)"; done)"
fi
if [ "$venv" = 1 ]; then
  "$d/.venv/bin/pip" install -q -r "$d/requirements.txt" || stop "pulled $d but pip install -r requirements.txt failed"
  echo "ok: synced $d/.venv from requirements.txt"
fi
'

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
did=0
reminded=0
for box in $BOXES; do
  [ "$box" = "$THIS" ] && continue
  did=1
  host="$(box_host "$box")"
  inst="$(repo_install "$REPO")"
  pipe="$(repo_pipeline "$REPO")"
  subs="$(repo_submodules "$REPO")"
  d="/srv/dev/repos/$REPO"

  # One-way SSH: the server can't reach the workstation. So when we're on the
  # server and the other box is the workstation, don't attempt the pull — just
  # remind Ethan to sync (and install) it there himself. Not a STOP.
  if [ "$THIS" = server ] && [ "$box" = workstation ]; then
    reminded=1
    echo "reminder: sync $REPO on the workstation (ethan-debian) yourself — the server can't SSH to it."
    echo "          run there (on its default branch, clean): git -C $d pull --ff-only${inst:+ && $inst}"
    continue
  fi

  mode=deploy; [ "$DRY" = 1 ] && mode=check
  set +e
  out="$(ssh $SSH_OPTS "$host" bash -s -- "$REPO" "$mode" "$pipe" "$subs" <<<"$REMOTE" 2>&1)"
  rc=$?
  set -e
  [ -n "$out" ] && printf '%s\n' "$out" | sed "s/^/[$box] /"
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 3 ]; then
      echo "STOP: $REPO not synced on $box ($host); see the [$box] STOP line above."
    else
      echo "STOP: ssh to $host failed (exit $rc); $REPO not synced on $box."
    fi
    exit 1
  fi

  if [ "$DRY" = 1 ]; then
    if [ -z "$inst" ]; then
      echo "would: pull $REPO on $box$( [ "$pipe" = 1 ] && echo ' (pipeline repo)'); no installer"
    elif [ "$box" = server ]; then
      echo "would: pull $REPO on $box, then run '$inst'"
    else
      echo "would: pull $REPO on $box; leave '$inst' to Ethan"
    fi
    continue
  fi

  if [ -z "$inst" ]; then
    echo "synced $box: $REPO pulled (no install step)"
  elif [ "$box" = server ]; then
    if ! ssh $SSH_OPTS "$host" "$inst"; then
      echo "STOP: pulled $REPO on $box but its install failed: $inst"
      exit 1
    fi
    echo "synced $box: $REPO pulled and '$inst' ran"
  else
    echo "synced $box: $REPO pulled; install left to Ethan ('$inst')"
  fi
done

if [ "$did" = 0 ]; then
  echo "RESULT: no-sync ($REPO deploys only to this box: $THIS)"
elif [ "$DRY" = 1 ]; then
  echo "RESULT: dry-run for $REPO: checks passed, nothing changed"
elif [ "$reminded" = 1 ]; then
  echo "RESULT: cross-box sync for $REPO: workstation pull/install left to Ethan (server can't SSH to it)"
else
  echo "RESULT: cross-box sync complete for $REPO"
fi
