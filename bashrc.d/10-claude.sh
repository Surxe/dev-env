# --- Claude Code shortcuts (dev user).
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
