# --- Coding-agent shortcuts (dev user).
# `cc` launches Claude Code with permission prompts bypassed. To start a fresh
# session, exit (Ctrl+D twice, or /exit) and run `cc` again — a new process gets
# a genuinely fresh identity, which `/clear` doesn't (it keeps a --name/rename
# and only drops the AI-generated title).
#
# Resolved by devsh/dev-cc and the tmux split scaffold inside an interactive dev
# shell (see users/ethan/.bashrc.d/10-devsh.sh and users/ethan/localbin/dev-cc):
# a function loads in interactive dev shells the same way an alias would.
cc() {
    claude --dangerously-skip-permissions "$@"
}

# Put the shared dev bins (~/.agents/bin, deployed by dev-env) on PATH so scripts
# like `wrf-pull` are runnable by name. Idempotent: skip if already present.
case ":${PATH}:" in
    *":$HOME/.agents/bin:"*) ;;
    *) export PATH="$HOME/.agents/bin:$PATH" ;;
esac

# Export the DeepSeek API key into the shell environment at startup, so `dsh`,
# `dsh-tui`, and any tool that reads DEEPSEEK_API_KEY from the environment work
# without a wrapper. The key lives in ~/.config/deepseek/env (mode 0600,
# dev-owned) and is never committed to this repo (see README).
if [ -f "$HOME/.config/deepseek/env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$HOME/.config/deepseek/env"
    set +a
fi

# `ds` launches the DeepSeek Harness (dsh) on the default profile. Override the
# profile per-shell with DSH_PROFILE (e.g. DSH_PROFILE=headless ds "run tests").
# Its permission default is danger-full-access via ~/.dsh/settings.yaml, so no
# skip-permissions flag is needed. The key is already exported above; ds()
# re-sources the env file as a fallback for shells started before it existed.
ds() {
    if [ -f "$HOME/.config/deepseek/env" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$HOME/.config/deepseek/env"
        set +a
    fi
    dsh --profile "${DSH_PROFILE:-dsh-tui}" "$@"
}

# Claude Code's TUI mouse capture is left ON (trial, todo t-0212). The fullscreen
# renderer draws on the alternate screen, so with the mouse released (below) the
# wheel had nothing to scroll -- tmux history is empty -- and PageUp didn't work
# mid-copy because the drag put tmux in copy mode. With capture on, Claude Code
# handles wheel scroll, in-app selection (copied on release via wl-copy), and
# Ctrl+click on links, including links wrapped across rows. Shift+drag still
# gives a native terminal selection; Ctrl+o then [ dumps the conversation into
# native scrollback for search/copy.
#
# Previously (todo t-0051) capture was fully released because its mouse
# tracking (v2.1.195+) intermittently desynced from the terminal, leaving the UI
# unclickable, and caused accidental prompt approvals. If that recurs, restore
# the line below; CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1 is the middle ground (wheel
# only, no clicks).
# export CLAUDE_CODE_DISABLE_MOUSE=1
