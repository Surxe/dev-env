#!/usr/bin/env bash
#
# install.sh — deploy the shared dev-env layer (portable skills, the cc/ds
# launchers, dev's git identity, the statusline, and universal memories) into
# dev's neutral `~/.agents` area on THIS box, then symlink the Claude-specific
# paths into `~/.claude`. The DeepSeek Harness reads skills from ~/.agents/skills
# natively and memory through the `memory-standard` plugin (deploy_dsh). The
# shared slice lives here once; each box gets it by running this script,
# configured by its hosts/<name>.env profile.
#
# Usage:  install.sh [--host <name>]
#   --host   workstation | home-server (default: autodetected from `hostname`)
#
# Runs everything AS dev: if invoked by ethan or root it re-execs itself as dev
# (via sudo -u dev / runuser), the same capability the machine-repo installers
# rely on. So it can be run standalone, or as one step of a machine repo's
# install.sh. Copy-based and additive (refreshes/adds; does not prune). Idempotent.
set -euo pipefail

SELF="$(readlink -f "$0")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"

# --- args ---
HOST=""
ALREADY_DEV=0
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-}"; shift 2;;
        --host=*) HOST="${1#*=}"; shift;;
        --already-dev) ALREADY_DEV=1; shift;;   # internal: set on the dev re-exec
        -h|--help) sed -n '2,14p' "$SELF"; exit 0;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

# --- resolve host (autodetect by hostname when not given) ---
if [ -z "$HOST" ]; then
    case "$(hostname)" in
        ethan-debian) HOST=workstation;;
        home-server)  HOST=home-server;;
        *) echo "ERROR: cannot autodetect host (hostname=$(hostname)); pass --host <name>" >&2; exit 2;;
    esac
fi
HOST_ENV="$HERE/hosts/$HOST.env"
[ -f "$HOST_ENV" ] || { echo "ERROR: no host profile: $HOST_ENV" >&2; exit 2; }

# --- run as dev: re-exec if we are not dev yet ---
ME="$(id -un)"
if [ "$ME" != dev ] && [ "$ALREADY_DEV" -ne 1 ]; then
    echo "== dev-env: re-exec as dev (from $ME) =="
    if [ "$ME" = root ]; then
        exec runuser -u dev -- "$SELF" --host "$HOST" --already-dev
    else
        exec sudo -u dev -- "$SELF" --host "$HOST" --already-dev
    fi
fi
[ "$(id -un)" = dev ] || { echo "ERROR: must run as dev (got $(id -un))" >&2; exit 1; }

echo "== dev-env install (host=$HOST) -> $(getent passwd dev | cut -d: -f6)/.agents =="

# --- load the host profile (exported so render sees the override vars) ---
set -a
# shellcheck disable=SC1090
source "$HOST_ENV"
set +a
: "${PROJECT:?host profile must set PROJECT}"

# shellcheck source=lib/deploy-claude.sh
source "$HERE/lib/deploy-claude.sh"

# --- render the layer into a transient stage, then deploy from it ---
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
render_tree "$HERE/skills"   "$STAGE/skills"
render_tree "$HERE/memory"   "$STAGE/memory"
render_tree "$HERE/bashrc.d" "$STAGE/bashrc.d"
[ -f "$HERE/statusline.py" ] && _render_file "$HERE/statusline.py" "$STAGE/statusline.py"
[ -d "$HERE/dsh" ] && render_tree "$HERE/dsh" "$STAGE/dsh"

deploy_skills        "$STAGE/skills"
deploy_memory        "$STAGE/memory" "$PROJECT"
deploy_bashrc        "$STAGE/bashrc.d"
deploy_gitconfig
deploy_statusline    "$STAGE/statusline.py"
deploy_dsh
deploy_dsh_statusbar "$STAGE/dsh"

echo "dev-env layer installed."
