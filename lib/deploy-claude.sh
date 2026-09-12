#!/usr/bin/env bash
#
# deploy-claude.sh — the shared install engine for the dev-env layer.
#
# SOURCED by install.sh, never executed. install.sh resolves the host, re-execs
# itself as `dev`, sources the host's hosts/<name>.env (exporting PROJECT, EXCLUDE
# and the per-box override vars), then sources THIS file and drives the deploy_*
# functions below. Because install.sh is already running as dev by the time these
# run, every function writes dev's own files directly — no sudo/runuser here.
#
# A sourced library must not mutate the caller's shell options, so this file does
# NOT `set -euo pipefail` (install.sh sets that for the whole run).

[ -n "${_DEVENV_DEPLOY_SOURCED:-}" ] && return 0
_DEVENV_DEPLOY_SOURCED=1

# DEV_HOME is dev's home; DEVENV_HOME_OVERRIDE redirects every write to a throwaway
# tree for testing (the install path never sets it).
DEV_HOME="${DEVENV_HOME_OVERRIDE:-$(getent passwd dev | cut -d: -f6)}"; : "${DEV_HOME:=/home/dev}"
CLAUDE_DIR="$DEV_HOME/.claude"

say(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- EXCLUDE: space-separated item names (skill dir / memory slug / bashrc
#     fragment basename) this host opts out of. Default empty = include all. ---
_excluded(){   # $1 = item name
    local e
    for e in ${EXCLUDE:-}; do [ "$e" = "$1" ] && return 0; done
    return 1
}

# --- render: substitute {{VAR}} placeholders from the environment (the host's
#     override vars) into a staged copy. Errors loudly on any unresolved
#     placeholder so a half-rendered file is never deployed. Text-only; there are
#     no binary assets in this layer. ---
_render_file(){   # $1 = src, $2 = dst
    python3 - "$1" "$2" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    text = f.read()
def sub(m):
    key = m.group(1)
    val = os.environ.get(key)
    if val is None:
        sys.stderr.write("unresolved placeholder {{%s}} in %s\n" % (key, src))
        sys.exit(3)
    return val
text = re.sub(r"\{\{([A-Z0-9_]+)\}\}", sub, text)
os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
PY
}

render_tree(){   # $1 = src dir, $2 = stage dir — render every file, preserve layout+mode
    local src="$1" stage="$2" f rel
    [ -d "$src" ] || return 0
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        mkdir -p "$stage/$(dirname "$rel")"
        _render_file "$f" "$stage/$rel" || die "render failed: $f"
        chmod --reference="$f" "$stage/$rel" 2>/dev/null || true
    done < <(find "$src" -type f -print0)
}

# --- deploy_skills: additive copy of staged skill dirs into ~dev/.claude/skills,
#     honoring EXCLUDE. Additive like the machine-repo installers: refreshes/adds,
#     does not prune skills removed from the repo. ---
deploy_skills(){   # $1 = staged skills dir
    local src="$1" dst="$CLAUDE_DIR/skills" d name
    [ -d "$src" ] || { say "skills: nothing to deploy"; return 0; }
    mkdir -p "$dst"
    for d in "$src"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        _excluded "$name" && { say "skills: EXCLUDE $name"; continue; }
        cp -a "$d." "$dst/$name/"
        say "skill -> $dst/$name"
    done
}

# --- deploy_memory: copy staged universal memory notes into this box's
#     project-scoped memory dir (-$PROJECT), honoring EXCLUDE, and merge the shared
#     index lines into that project's MEMORY.md inside a delimited block (so the
#     box-local entries are left intact). The only per-box difference is $PROJECT
#     (srv-dev vs home-dev). MEMORY.shared.md (the index fragment) and MEMORY.md
#     itself are never deployed as memory notes. ---
_MEM_BEGIN="<!-- BEGIN dev-env shared memories (managed by dev-env/install.sh) -->"
_MEM_END="<!-- END dev-env shared memories -->"
deploy_memory(){   # $1 = staged memory dir, $2 = project slug
    local src="$1" project="$2"
    local dst="$CLAUDE_DIR/projects/-$project/memory"
    local f name frag="$src/MEMORY.shared.md" live="$dst/MEMORY.md"
    [ -d "$src" ] || { say "memory: nothing to deploy"; return 0; }
    [ -n "$project" ] || die "deploy_memory: no PROJECT set for this host"
    mkdir -p "$dst"
    for f in "$src"/*.md; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .md)"
        case "$name" in MEMORY|MEMORY.shared) continue;; esac
        _excluded "$name" && { say "memory: EXCLUDE $name"; continue; }
        cp -a "$f" "$dst/$(basename "$f")"
        say "memory -> $dst/$(basename "$f")"
    done
    [ -f "$frag" ] || { say "memory: no MEMORY.shared.md index fragment"; return 0; }
    _merge_memory_index "$frag" "$live"
    say "memory: merged shared index block -> $live"
}

_merge_memory_index(){   # $1 = fragment file, $2 = live MEMORY.md
    local frag="$1" live="$2"
    MEM_BEGIN="$_MEM_BEGIN" MEM_END="$_MEM_END" python3 - "$frag" "$live" <<'PY'
import os, sys
frag, live = sys.argv[1], sys.argv[2]
begin, end = os.environ["MEM_BEGIN"], os.environ["MEM_END"]
with open(frag, encoding="utf-8") as f:
    lines = [ln.rstrip("\n") for ln in f if ln.strip()]
block = "\n".join([begin, *lines, end]) + "\n"
try:
    with open(live, encoding="utf-8") as f:
        cur = f.read()
except FileNotFoundError:
    cur = "# Memory index\n"
# Drop any existing managed block, then append a fresh one.
if begin in cur and end in cur:
    pre = cur[: cur.index(begin)]
    post = cur[cur.index(end) + len(end):]
    cur = pre.rstrip("\n") + "\n" + post.lstrip("\n")
cur = cur.rstrip("\n") + "\n\n" + block
os.makedirs(os.path.dirname(live) or ".", exist_ok=True)
with open(live, "w", encoding="utf-8") as f:
    f.write(cur)
PY
}

# --- deploy_bashrc: copy staged .bashrc.d fragments into ~dev/.bashrc.d, honoring
#     EXCLUDE, and ensure ~/.bashrc actually sources ~/.bashrc.d/*.sh (the server's
#     dev may lack the loader bootstrap my-system assumes). ---
deploy_bashrc(){   # $1 = staged bashrc.d dir
    local src="$1" dst="$DEV_HOME/.bashrc.d" f name bashrc="$DEV_HOME/.bashrc"
    [ -d "$src" ] || { say "bashrc: nothing to deploy"; return 0; }
    mkdir -p "$dst"
    for f in "$src"/*.sh; do
        [ -e "$f" ] || continue
        name="$(basename "$f")"
        _excluded "${name%.sh}" && { say "bashrc: EXCLUDE $name"; continue; }
        install -D -m 0644 "$f" "$dst/$name"
        say "bashrc -> $dst/$name"
    done
    # One-time loader bootstrap: make ~/.bashrc source the fragment dir.
    if [ -f "$bashrc" ] && grep -q '\.bashrc\.d' "$bashrc"; then
        say "bashrc: loader already present in $bashrc"
    else
        cat >> "$bashrc" <<'LOADER'

# Load ~/.bashrc.d/*.sh fragments (added by dev-env).
if [ -d "$HOME/.bashrc.d" ]; then
    for _f in "$HOME"/.bashrc.d/*.sh; do [ -r "$_f" ] && . "$_f"; done
    unset _f
fi
LOADER
        say "bashrc: added ~/.bashrc.d loader to $bashrc"
    fi
}

# --- deploy_gitconfig: dev's GLOBAL git author identity. Shared and constant
#     across boxes (credit routes to Surxe via the +noreply author email, while
#     the push still uses whichever PAT). Lifted from my-system dev-gitconfig.sh;
#     overwrites only these two keys, idempotent. ---
DEV_GIT_NAME="Surxe-dev"
DEV_GIT_EMAIL="119145352+Surxe@users.noreply.github.com"
deploy_gitconfig(){
    git config --global user.name  "$DEV_GIT_NAME"
    git config --global user.email "$DEV_GIT_EMAIL"
    say "git identity -> $DEV_GIT_NAME <$DEV_GIT_EMAIL>"
}

# --- deploy_statusline: copy statusline.py + idempotently wire settings.json's
#     statusLine key without disturbing other keys. Lifted from dev-statusline.sh;
#     warns (not fails) if the self-test does not pass. ---
deploy_statusline(){   # $1 = staged statusline.py
    local src="$1" dst="$CLAUDE_DIR/statusline.py" settings="$CLAUDE_DIR/settings.json"
    [ -e "$src" ] || { say "statusline: no source — skipping"; return 0; }
    install -D -m 0644 "$src" "$dst"
    say "statusline -> $dst"
    python3 - "$settings" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except (OSError, ValueError):
    data = {}
data["statusLine"] = {"type": "command", "command": "python3 ~/.claude/statusline.py"}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(data, indent=2) + "\n")
PY
    say "statusline: wired -> $settings"
    if python3 "$dst" --selftest >/dev/null 2>&1; then
        say "statusline: self-test passed"
    else
        say "!! statusline: self-test FAILED — check $dst"
    fi
}
