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
# Provider-neutral layout: this engine installs the SHARED slice (skills, memory,
# statusline) into `~/.agents/`, the neutral root; each machine repo installs its
# box-local skills/memory and its global AGENTS.md into the same root. Claude Code
# consumes it through symlinks into `~/.claude` (skills/, CLAUDE.md,
# projects/-<project>/memory, statusline.py); the DeepSeek Harness consumes skills
# directly from `~/.agents/skills` and memory through the `memory-standard` plugin
# rooted at `~/.dsh/memory` (see deploy_dsh / deploy_dsh_memory).
#
# A sourced library must not mutate the caller's shell options, so this file does
# NOT `set -euo pipefail` (install.sh sets that for the whole run).

[ -n "${_DEVENV_DEPLOY_SOURCED:-}" ] && return 0
_DEVENV_DEPLOY_SOURCED=1

# DEV_HOME is dev's home; DEVENV_HOME_OVERRIDE redirects every write to a throwaway
# tree for testing (the install path never sets it).
DEV_HOME="${DEVENV_HOME_OVERRIDE:-$(getent passwd dev | cut -d: -f6)}"; : "${DEV_HOME:=/home/dev}"
CLAUDE_DIR="$DEV_HOME/.claude"
AGENTS_DIR="$DEV_HOME/.agents"
# The DeepSeek Harness home is ~/.dsh by default; we derive it from DEV_HOME (not
# the DSH_HOME env) so DEVENV_HOME_OVERRIDE redirects every write for testing.
DSH_HOME_DIR="$DEV_HOME/.dsh"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say(){ printf '  %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- EXCLUDE: space-separated item names (skill dir / memory slug / bashrc
#     fragment basename) this host opts out of. Default empty = include all. ---
_excluded(){   # $1 = item name
    local e
    for e in ${EXCLUDE:-}; do [ "$e" = "$1" ] && return 0; done
    return 1
}

# --- _ensure_symlink: point a live Claude/DSH path at a neutral ~/.agents target.
#     Idempotent; replaces a stale symlink, and a pre-existing real file/dir (the
#     one-time migration from the old copy-into-~/.claude layout) is moved aside to
#     <path>.pre-agents rather than deleted, so nothing is silently destroyed. ---
_ensure_symlink(){   # $1 = target (must exist), $2 = link path
    local target="$1" link="$2"
    [ -e "$target" ] || [ -L "$target" ] || { say "symlink: target missing: $target"; return 1; }
    if [ -L "$link" ]; then
        [ "$(readlink "$link")" = "$target" ] && return 0
        rm -f "$link"
    elif [ -e "$link" ]; then
        local bak="$link.pre-agents"
        rm -rf "$bak"
        mv "$link" "$bak"
        say "symlink: moved existing $link -> $bak"
    fi
    mkdir -p "$(dirname "$link")"
    ln -s "$target" "$link"
    say "symlink: $link -> $target"
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

# --- deploy_skills: additive copy of staged skill dirs into ~/.agents/skills
#     (the neutral root), honoring EXCLUDE, then symlink ~/.claude/skills to it.
#     The DeepSeek Harness scans ~/.agents/skills natively (user-agents root), so
#     one copy serves both agents. Additive like the machine-repo installers:
#     refreshes/adds, does not prune skills removed from the repo. ---
deploy_skills(){   # $1 = staged skills dir
    local src="$1" dst="$AGENTS_DIR/skills" d name
    [ -d "$src" ] || { say "skills: nothing to deploy"; return 0; }
    mkdir -p "$dst"
    for d in "$src"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        _excluded "$name" && { say "skills: EXCLUDE $name"; continue; }
        cp -a "$d." "$dst/$name/"
        say "skill -> $dst/$name"
    done
    _ensure_symlink "$dst" "$CLAUDE_DIR/skills"
}

# --- deploy_memory: copy staged universal memory notes into the neutral
#     ~/.agents/memory dir (flat, Claude Code format), honoring EXCLUDE, and merge
#     the shared index lines into its MEMORY.md inside a delimited block (so the
#     box-local entries are left intact). Claude consumes it via a symlinked
#     project memory dir; the DeepSeek Harness gets the same notes rendered into
#     the memory-standard layout under ~/.dsh/memory (see deploy_dsh_memory).
#     The only per-box difference is $PROJECT (the box's cwd slug; both boxes are
#     currently srv-dev). MEMORY.shared.md
#     (the index fragment) and MEMORY.md itself are never deployed as notes. ---
_MEM_BEGIN="<!-- BEGIN dev-env shared memories (managed by dev-env/install.sh) -->"
_MEM_END="<!-- END dev-env shared memories -->"
deploy_memory(){   # $1 = staged memory dir, $2 = project slug
    local src="$1" project="$2"
    local dst="$AGENTS_DIR/memory"
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
    _ensure_symlink "$dst" "$CLAUDE_DIR/projects/-$project/memory"
    deploy_dsh_memory "$src"
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

# --- deploy_dsh_memory: render the staged Claude-format notes into the
#     memory-standard (mm) layout at $DSH_HOME_DIR/memory, which the
#     `memory-standard` plugin reads as its root. Only the notes this call owns
#     (the shared slice) are written; box-local notes are rendered by the machine
#     repo's own installer, and lib/memory-standard.py leaves foreign `## <topic>`
#     sections untouched, so the two slices coexist in one index. ---
deploy_dsh_memory(){   # $1 = staged memory dir (Claude-format notes)
    local src="$1" tmp f name
    [ -d "$src" ] || return 0
    command -v python3 >/dev/null || { say "dsh memory: no python3 — skipping"; return 0; }
    tmp="$(mktemp -d)"
    for f in "$src"/*.md; do
        [ -e "$f" ] || continue
        name="$(basename "$f" .md)"
        case "$name" in MEMORY|MEMORY.shared) continue;; esac
        _excluded "$name" && continue
        cp -a "$f" "$tmp/"
    done
    python3 "$LIB_DIR/memory-standard.py" render --src "$tmp" --dst "$DSH_HOME_DIR/memory" || \
        say "!! dsh memory render failed (see above)"
    rm -rf "$tmp"
}

# --- _find_dsh: locate the DeepSeek Harness `dsh` CLI, which is optional wiring.
#     `sudo -u dev` resets PATH to sudo's secure_path, so we also probe the nvm
#     node bins and ~/.local/bin rather than trusting `command -v` alone. ---
_find_dsh(){
    local c
    c="$(command -v dsh 2>/dev/null || true)"
    [ -n "$c" ] && { echo "$c"; return 0; }
    local nvmbin
    nvmbin="$(ls -d "$DEV_HOME"/.nvm/versions/node/*/bin/dsh 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$nvmbin" ] && [ -x "$nvmbin" ] && { echo "$nvmbin"; return 0; }
    [ -x "$DEV_HOME/.local/bin/dsh" ] && { echo "$DEV_HOME/.local/bin/dsh"; return 0; }
    return 1
}

# --- deploy_dsh: install the `memory-standard` plugin into the DeepSeek Harness
#     profile so dsh agents get mem_read/mem_write/mem_search/mem_budget/mem_digest.
#     Best-effort (like dev-mcp): if dsh / git / npm is missing it skips instead of
#     failing the deploy. The plugin's lib/ is gitignored (TypeScript source only),
#     so it is vendored + built once, then path-installed into the profile. ---
deploy_dsh(){
    local dsh profile vendor
    dsh="$(_find_dsh || true)"
    [ -n "$dsh" ] || { say "dsh: 'dsh' not found — skipping memory-standard plugin"; return 0; }
    # dsh is a node CLI (`#!/usr/bin/env node`). install.sh runs via `sudo -u dev`,
    # whose secure_path drops the nvm bin dir, so `env node` (and `command -v npm`
    # below) fail even though _find_dsh located dsh there. Put dsh's own bin dir on
    # PATH first so every dsh/npm call resolves node.
    export PATH="$(dirname "$dsh"):$PATH"
    profile="${DSH_PROFILE:-dsh-tui}"
    if "$dsh" --profile "$profile" --dump-config 2>/dev/null | grep -q 'memory-standard'; then
        say "dsh: memory-standard already wired into '$profile'"
        return 0
    fi
    vendor="${DSH_PLUGIN_VENDOR:-$DEV_HOME/.local/share/dsh/plugins}/memory-standard"
    if [ ! -f "$vendor/lib/index.js" ]; then
        command -v git >/dev/null || { say "dsh: git not found — skipping memory-standard plugin"; return 0; }
        command -v npm >/dev/null || { say "dsh: npm not found — skipping memory-standard plugin"; return 0; }
        mkdir -p "$(dirname "$vendor")"
        git clone --depth 1 https://github.com/JohnXu22786/memory-standard.git "$vendor" || \
            { say "dsh: clone of memory-standard failed — skipping"; return 0; }
        ( cd "$vendor" && npm install --ignore-scripts && npm run build ) || \
            { say "dsh: build of memory-standard failed — skipping"; return 0; }
    fi
    "$dsh" plugin --profile "$profile" add "$vendor" || \
        { say "dsh: 'plugin add' failed — see output above"; return 0; }
    say "dsh: memory-standard plugin wired into '$profile'"
}

# --- deploy_dsh_statusbar: install the dsh-tui status bar (host · model · ctx% ·
#     repo) into the DeepSeek Harness profile. Copies statusbar.mjs into the
#     profile dir and mounts it via the profile's own cordis.patch.yml (the
#     user-owned patch surface, applied after every bundle layer). Best-effort:
#     skips (warns, never fails) if the profile dir is absent. Idempotent — and
#     it will NOT clobber a cordis.patch.yml the user has hand-edited. ---
deploy_dsh_statusbar(){   # $1 = staged dsh dir (statusbar.mjs + cordis.patch.yml)
    local src="$1" profile profdir dest stripped
    [ -d "$src" ] || { say "dsh statusbar: no source — skipping"; return 0; }
    [ -f "$src/statusbar.mjs" ] || { say "dsh statusbar: no statusbar.mjs — skipping"; return 0; }
    profile="${DSH_PROFILE:-dsh-tui}"
    profdir="$DSH_HOME_DIR/profiles/$profile"
    if [ ! -d "$profdir" ]; then
        say "dsh statusbar: profile '$profile' not installed ($profdir) — skipping"
        return 0
    fi

    # The plugin file itself is always refreshed (it is dev-env-owned).
    install -D -m 0644 "$src/statusbar.mjs" "$profdir/statusbar.mjs"
    say "dsh statusbar -> $profdir/statusbar.mjs"

    # Wire the mount into the profile's cordis.patch.yml (the user surface).
    dest="$profdir/cordis.patch.yml"
    if [ -f "$dest" ] && grep -q 'dev-status-bar' "$dest"; then
        say "dsh statusbar: already wired in $dest"
        return 0
    fi
    # Stock/empty check: strip comment + blank lines and whitespace; the stock
    # file is exactly `[]` (or empty). Anything else is a user-authored patch.
    if [ -f "$dest" ]; then
        stripped="$(grep -vE '^[[:space:]]*(#|$)' "$dest" | tr -d '[:space:]')"
    else
        stripped=""
    fi
    if [ -z "$stripped" ] || [ "$stripped" = "[]" ]; then
        install -D -m 0644 "$src/cordis.patch.yml" "$dest"
        say "dsh statusbar: wired mount -> $dest"
    else
        say "!! dsh statusbar: $dest has custom entries — not modifying."
        say "   Add the dev-status-bar row from $src/cordis.patch.yml manually."
    fi
}

# --- deploy_bashrc: copy staged .bashrc.d fragments into ~/.bashrc.d, honoring
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
    # Harden the Debian non-interactive guard: `return` at top level only works when
    # ~/.bashrc is sourced, so if the file is ever executed (e.g. `bash ~/.bashrc`)
    # it errors on that line. Rewrite it to the sourced-or-exit form, idempotently.
    if [ -f "$bashrc" ] && grep -q '^[[:space:]]*\*) return;;' "$bashrc"; then
        sed -i 's#^\([[:space:]]*\)\*) return;;#\1*) return 2>/dev/null || exit 0;;#' "$bashrc"
        say "bashrc: hardened non-interactive guard in $bashrc"
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

# --- deploy_statusline: copy statusline.py into ~/.agents, symlink it into
#     ~/.claude, and idempotently wire settings.json's statusLine key without
#     disturbing other keys. Lifted from dev-statusline.sh; warns (not fails) if
#     the self-test does not pass. ---
deploy_statusline(){   # $1 = staged statusline.py
    local src="$1" dst="$AGENTS_DIR/statusline.py" settings="$CLAUDE_DIR/settings.json"
    [ -e "$src" ] || { say "statusline: no source — skipping"; return 0; }
    install -D -m 0644 "$src" "$dst"
    say "statusline -> $dst"
    _ensure_symlink "$dst" "$CLAUDE_DIR/statusline.py"
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

# --- deploy_sessionstart_hostname: wire a SessionStart hook into settings.json
#     (merge-only, idempotent) that injects the live hostname into context at the
#     start of every session, so the model detects the active box directly instead
#     of inferring it. Shared -> runs on both boxes; each resolves its own hostname
#     at session start. The active-box memory maps the hostname to the box name. ---
deploy_sessionstart_hostname(){
    local settings="$CLAUDE_DIR/settings.json"
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
cmd = ('printf \'{"hookSpecificOutput":{"hookEventName":"SessionStart",'
       '"additionalContext":"Active hostname: %s"}}\\n\' "$(hostname)"')
ss = data.setdefault("hooks", {}).setdefault("SessionStart", [])
present = any(
    isinstance(g, dict) and any(
        isinstance(h, dict) and h.get("command") == cmd for h in g.get("hooks", [])
    )
    for g in ss
)
if not present:
    ss.append({"hooks": [{"type": "command", "command": cmd}]})
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(data, indent=2) + "\n")
PY
    say "sessionstart: wired hostname hook -> $settings"
}
