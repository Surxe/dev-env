#!/usr/bin/env python3
"""Single-line Claude Code status bar.

Reads the status-line JSON payload on stdin and prints ONE line (no trailing
newline segments, no vertical growth). Layout:

    <model>  ·  ctx N%  ·  5h N%  ·  wk N%  ·  <repo>

Percentages are color-coded green/yellow/red by fullness. The 5h/wk rate-limit
segments are account-wide (across all sessions) and are simply omitted when the
payload doesn't carry them (early in a session, or non Pro/Max).

The final segment is the active repository under /srv/dev/repos. When the cwd is
inside a specific repo (repos/<repo>/...), that repo name is shown directly. When
Claude is launched from the repos root itself (/srv/dev/repos), the active repo
is instead inferred from the most recently touched path in the session transcript
so the bar still names what's being worked on.

Deployed to ~/.claude/statusline.py by my-system's users/install.sh and wired in
as settings.json -> statusLine. Stdlib only; must never crash the bar.
"""

import io
import json
import os
import re
import sys

# Force UTF-8 stdout so the middot separator never trips a narrow locale.
if hasattr(sys.stdout, "buffer"):
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

SEP = " \x1b[2m·\x1b[0m "  # dim middle dot between segments

_ANSI = {
    "reset": "\x1b[0m",
    "bold": "\x1b[1m",
    "dim": "\x1b[2m",
    "green": "\x1b[32m",
    "yellow": "\x1b[33m",
    "red": "\x1b[31m",
    "cyan": "\x1b[36m",
}

# Percentage color thresholds (<=green stays green, <=yellow is yellow, else red).
T_GREEN = 60
T_YELLOW = 80

# All of Ethan's repos live directly under this root.
REPOS_ROOT = "/srv/dev/repos"
# Matches REPOS_ROOT/<name>, capturing the repo directory name. Stops at the next
# separator or any whitespace/quote so it works on both bare paths and paths
# embedded in Bash command strings.
_REPO_RE = re.compile(re.escape(REPOS_ROOT) + r"/([^/\s\"'\\]+)")


def _c(text, *codes):
    return "".join(_ANSI[c] for c in codes if c in _ANSI) + text + _ANSI["reset"]


def _pct_color(pct):
    if pct <= T_GREEN:
        return "green"
    if pct <= T_YELLOW:
        return "yellow"
    return "red"


def _num(v):
    """Coerce a possibly-null/str numeric to float, or None."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _model(data):
    name = (data.get("model") or {}).get("display_name") or ""
    # Strip a trailing "(… context)" suffix, e.g. "Opus (1M context)".
    if "(" in name:
        name = name[: name.rfind("(")].strip()
    return name


def _repo_from_path(path):
    """Return the repo name if `path` is inside REPOS_ROOT/<name>, else None.

    The repos root itself (no specific repo) yields None so callers can fall
    back to transcript inference.
    """
    if not path:
        return None
    norm = os.path.normpath(path)
    prefix = REPOS_ROOT + os.sep
    if not norm.startswith(prefix):
        return None
    name = norm[len(prefix):].split(os.sep, 1)[0]
    return name or None


def _tool_input_strings(obj):
    """Yield the string values of any tool_use inputs in a transcript line.

    Restricting to tool_use inputs (not raw line text) avoids matching the repo
    listing that appears in CLAUDE.md / system-reminder context, so only real
    file/command activity is considered.
    """
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return
    content = msg.get("content")
    if not isinstance(content, list):
        return
    for block in content:
        if isinstance(block, dict) and block.get("type") == "tool_use":
            inp = block.get("input")
            if isinstance(inp, dict):
                for v in inp.values():
                    if isinstance(v, str):
                        yield v


def _repo_from_transcript(path):
    """Infer the most recently touched repo from tool activity in the transcript."""
    if not path or not os.path.isfile(path):
        return None
    found = None
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if REPOS_ROOT not in line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                for text in _tool_input_strings(obj):
                    for m in _REPO_RE.finditer(text):
                        found = m.group(1)  # keep the last match (most recent)
    except OSError:
        return None
    return found


def _active_repo(data):
    """The repo to display: the cwd's repo, else the transcript-inferred repo,
    else the plain cwd folder name."""
    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
    repo = _repo_from_path(cwd)
    if repo:
        return repo
    repo = _repo_from_transcript(data.get("transcript_path"))
    if repo:
        return repo
    return os.path.basename(cwd.rstrip("/")) if cwd else ""


def render(data):
    parts = []

    model = _model(data)
    if model:
        parts.append(model)

    # Context %
    cw = data.get("context_window") or {}
    ctx = _num(cw.get("used_percentage")) or 0.0
    parts.append("ctx " + _c(f"{ctx:.0f}%", _pct_color(ctx)))

    # Rate-limit windows (account-wide). Each may be absent.
    rl = data.get("rate_limits") or {}
    for key, label in (("five_hour", "5h"), ("seven_day", "wk")):
        window = rl.get(key) or {}
        val = _num(window.get("used_percentage"))
        if val is not None:
            parts.append(f"{label} " + _c(f"{val:.0f}%", _pct_color(val)))

    # Active repo
    repo = _active_repo(data)
    if repo:
        parts.append(_c(repo, "bold", "cyan"))

    return SEP.join(parts)


# --- self-test -------------------------------------------------------------

MOCK_FULL = {
    "model": {"display_name": "Opus (1M context)"},
    "context_window": {"used_percentage": 8},
    "rate_limits": {
        "five_hour": {"used_percentage": 23.5},
        "seven_day": {"used_percentage": 41.2},
    },
    "workspace": {"current_dir": "/srv/dev/repos/my-system"},
}

MOCK_BARE = {
    # no rate_limits, null context -> no 5h/wk, ctx 0%
    "model": {"display_name": "Opus"},
    "context_window": {"used_percentage": None},
    "workspace": {"current_dir": "/srv/dev/repos/todo"},
}


def selftest():
    import tempfile

    ok = True
    for label, mock, want_repo in [
        ("full payload", MOCK_FULL, "my-system"),
        ("bare payload", MOCK_BARE, "todo"),
    ]:
        out = render(mock)
        if not out.strip() or "\n" in out:
            print(f"FAIL: {label}: empty or multi-line output", file=sys.stderr)
            ok = False
            continue
        if want_repo not in out:
            print(f"FAIL: {label}: expected repo '{want_repo}' in output", file=sys.stderr)
            ok = False
        print(f"--- {label} ---")
        print(out)

    # Repos-root case: cwd is the repos root, so the active repo must be inferred
    # from tool activity in the transcript.
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as tf:
        tf.write(json.dumps({
            "type": "assistant",
            "message": {"content": [
                {"type": "tool_use", "input": {"file_path": "/srv/dev/repos/steam-price-tracker/main.py"}},
            ]},
        }) + "\n")
        tf.write(json.dumps({
            "type": "assistant",
            "message": {"content": [
                {"type": "tool_use", "input": {"command": "cd /srv/dev/repos/dev-summary && ls"}},
            ]},
        }) + "\n")
        transcript = tf.name
    try:
        mock = {
            "model": {"display_name": "Opus"},
            "context_window": {"used_percentage": 12},
            "workspace": {"current_dir": REPOS_ROOT},
            "transcript_path": transcript,
        }
        out = render(mock)
        # dev-summary was the most recent activity, so it wins over steam-price-tracker.
        if "dev-summary" not in out:
            print("FAIL: repos-root: expected inferred repo 'dev-summary' in output", file=sys.stderr)
            ok = False
        print("--- repos-root (inferred) ---")
        print(out)
    finally:
        os.unlink(transcript)

    return ok


def main():
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    try:
        data = json.loads(sys.stdin.read())
        print(render(data))
    except Exception:
        # Never crash the status bar; emit an empty line.
        print("")
        sys.exit(0)


if __name__ == "__main__":
    main()
