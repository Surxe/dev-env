#!/usr/bin/env bash
#
# sync-box.sh — cross-box sync for the /merged skill.
#
# After /merged cleans a box repo locally, the same change must land on every
# OTHER box that repo deploys to (sibling clones under /srv/dev/repos). This
# script pulls the clone on each other box over SSH, then on the SERVER runs the
# repo's install.sh. On the workstation (ethan-debian) install.sh is never
# auto-run — it is left to Ethan and only reported here.
#
# Usage:  sync-box.sh [<repo>] [--dry-run]
#   <repo>     path or name of the merged repo (default: git toplevel of cwd).
#   --dry-run  print the planned SSH actions; touch nothing.
#
# Data-driven: the three case tables below (repo -> boxes, box -> ssh host,
# repo -> install command) are the whole policy. Prints one RESULT:/STOP: line to
# read off. Exits non-zero only when a needed sync actually failed.
#
# SSH direction: workstation -> server works via the `home-server` alias in
# ~/.ssh/config. server -> workstation ("ethan-debian") needs the server to have
# its own SSH key + host resolution, which is not set up today — that direction
# fails loudly with a STOP and Ethan pulls/installs there manually.
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
    # — the deploy is the git pull; the units run the fresh code on their next tick.
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
                 # Empty = pull-only (project repos with no installer of their own).
  case "$1" in
    dev-env)        echo "/srv/dev/repos/dev-env/install.sh" ;;
    my-system)      echo "/srv/dev/repos/my-system/users/install.sh" ;;
    home-server)    echo "sudo -n /srv/dev/repos/home-server/install.sh" ;;
    valheim-server) echo "sudo -n /srv/dev/repos/valheim-server/install.sh" ;;
    *)              echo "" ;;
  esac
}

BOXES="$(repo_boxes "$REPO")"
if [ -z "$BOXES" ]; then
  echo "RESULT: no-sync ($REPO is not a box repo)"
  exit 0
fi

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10"
did=0
for box in $BOXES; do
  [ "$box" = "$THIS" ] && continue
  did=1
  host="$(box_host "$box")"
  inst="$(repo_install "$REPO")"
  pull="git -C /srv/dev/repos/$REPO fetch --prune && git -C /srv/dev/repos/$REPO pull --ff-only"

  if [ "$DRY" = 1 ]; then
    echo "would: ssh $host '$pull'"
    if [ -z "$inst" ]; then
      echo "would: (no installer for $REPO) pull only"
    elif [ "$box" = server ]; then
      echo "would: ssh $host '$inst'"
    else
      echo "would: (workstation) pull only; leave '$inst' to Ethan"
    fi
    continue
  fi

  if ! ssh $SSH_OPTS "$host" "$pull"; then
    echo "STOP: could not pull $REPO on $box ($host)." >&2
    echo "      manual: ssh $host '$pull'" >&2
    exit 1
  fi
  if [ -z "$inst" ]; then
    # Project repo with no installer of its own: the pull is the deploy.
    echo "synced $box: pulled $REPO (no install step)"
  elif [ "$box" = server ]; then
    if ! ssh $SSH_OPTS "$host" "$inst"; then
      echo "STOP: pulled $REPO on $box but its install failed: $inst" >&2
      exit 1
    fi
    echo "synced $box: pulled $REPO and ran '$inst'"
  else
    echo "synced $box: pulled $REPO; install.sh left to Ethan ('$inst')"
  fi
done

if [ "$did" = 0 ]; then
  echo "RESULT: no-sync ($REPO deploys only to this box: $THIS)"
else
  echo "RESULT: cross-box sync complete for $REPO"
fi
