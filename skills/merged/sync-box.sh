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
#   2. fast-forwards the default branch (`pull --ff-only`).
#   3. syncs the repo's Python venv when it has one (`.venv` + requirements.txt),
#      since a new requirement otherwise silently degrades the service.
#   4. on the SERVER runs the repo's install command, if it has one. On the
#      workstation (ethan-debian) install is never auto-run — left to Ethan.
#
# Usage:  sync-box.sh [<repo>] [--dry-run]
#   <repo>     path or name of the merged repo (default: git toplevel of cwd).
#   --dry-run  run the step-1 checks on each other box, print the plan; change nothing.
#
# Data-driven: the case tables below (repo -> boxes, box -> ssh host,
# repo -> install command, repo -> pipeline guard) are the whole policy. Prints
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
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
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

BOXES="$(repo_boxes "$REPO")"
if [ -z "$BOXES" ]; then
  echo "RESULT: no-sync ($REPO is not a box repo)"
  exit 0
fi

# Runs ON the target box (bash -s). Args: repo, mode (check|deploy), pipeline (0|1).
# Prints "ok: ..." lines; on a failed check prints "STOP: ..." and exits 3.
# shellcheck disable=SC2016
REMOTE='
set -uo pipefail
repo="$1"; mode="$2"; pipeline="$3"
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
[ -z "$dirty" ] || stop "$d has uncommitted tracked changes; not touching it: $(echo "$dirty" | head -3 | tr "\n" " ")"
if [ "$pipeline" = 1 ]; then
  active=$(systemctl list-units "wrf-orchestrator@*" --state=activating,active --no-legend 2>/dev/null | awk "{print \$1}" | tr "\n" " ")
  [ -z "$active" ] || stop "a WRF pipeline run is active ($active); pulling now would change code mid-run. Re-run after it finishes."
fi
behind=$(git -C "$d" rev-list --count "HEAD..origin/$def")
venv=0; [ -x "$d/.venv/bin/pip" ] && [ -f "$d/requirements.txt" ] && venv=1
if [ "$mode" = check ]; then
  echo "ok: $d on $def, clean, $behind commit(s) behind origin/$def$([ "$venv" = 1 ] && echo ", venv to sync")"
  exit 0
fi
git -C "$d" pull --ff-only -q || stop "pull --ff-only failed in $d"
echo "ok: pulled $d to $(git -C "$d" log -1 --format=%h) ($behind new commit(s))"
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
  out="$(ssh $SSH_OPTS "$host" bash -s -- "$REPO" "$mode" "$pipe" <<<"$REMOTE" 2>&1)"
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
