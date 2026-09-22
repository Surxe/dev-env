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

# Fully release Claude Code's TUI mouse capture. Its mouse tracking (v2.1.195+)
# intermittently desyncs from the terminal, leaving the UI unclickable /
# interactions silently dropped, and also causes accidental prompt approvals.
# The milder CLAUDE_CODE_DISABLE_MOUSE_CLICKS keeps the scroll wheel but leaves
# mouse reporting on, which still swallows click-drag so native text selection /
# copy stays broken. CLAUDE_CODE_DISABLE_MOUSE=1 releases the mouse entirely:
# click-drag selection + terminal copy work with no modifier. Trade-off is no
# scroll wheel (scroll with PageUp / Ctrl); prompts are answered with arrow keys
# + Enter. (todo t-0051)
export CLAUDE_CODE_DISABLE_MOUSE=1
