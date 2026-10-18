#!/usr/bin/env python3
"""claude-settings.py — merge-only, idempotent edits to a Claude Code settings.json.

Shared by dev-env's deploy engine (lib/deploy-claude.sh) and the machine repos'
installers, so every step that wires a key or hook into settings.json goes through
one load/modify/write path instead of its own inline copy.

A missing file starts from {}. A file that does not parse as a JSON object is an
ERROR and is left untouched — never silently replaced with just the one key. The
write is atomic (temp file in the same dir + os.replace) and keeps the file mode.

Dependency-free (Python stdlib only).

Hooks are normally DECLARED rather than added one by one: a repo that owns hooks
keeps a hooks.json listing them and its installer runs `apply-hooks` on it. Format:

    {"hooks": [
        {"event": "SessionStart", "command": "...", "why": "free text, ignored"},
        {"event": "PreToolUse", "matcher": "Bash", "command": "..."}
    ]}

`apply-hooks` is additive like `add-hook` (a hook already wired with that exact
command is left alone; nothing is pruned), and validates the whole list before
touching the file.

Usage:
    claude-settings.py --file PATH set KEY JSON_VALUE
    claude-settings.py --file PATH add-hook EVENT COMMAND [--matcher M]
    claude-settings.py --file PATH apply-hooks HOOKS_JSON
    claude-settings.py --selftest
"""

import argparse
import json
import os
import sys
import tempfile


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    try:
        data = json.loads(text)
    except ValueError as e:
        sys.exit("claude-settings: %s is not valid JSON (%s) — not modifying" % (path, e))
    if not isinstance(data, dict):
        sys.exit("claude-settings: %s is not a JSON object — not modifying" % path)
    return data


def save(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".settings.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, indent=2) + "\n")
        try:
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        except FileNotFoundError:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def set_key(data, key, value):
    data[key] = value


def add_hook(data, event, cmd, matcher=None):
    """Append a command hook to EVENT unless that exact command is already wired
    (under any matcher). MATCHER, when given, scopes the new group (tool events)."""
    groups = data.setdefault("hooks", {}).setdefault(event, [])
    present = any(
        isinstance(g, dict) and any(
            isinstance(h, dict) and h.get("command") == cmd for h in g.get("hooks", [])
        )
        for g in groups
    )
    if not present:
        group = {"hooks": [{"type": "command", "command": cmd}]}
        if matcher is not None:
            group = {"matcher": matcher, **group}
        groups.append(group)


def load_hook_list(path):
    """Parse and validate a declared hooks.json; exit (file untouched) on any error."""
    try:
        with open(path, encoding="utf-8") as f:
            decl = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit("claude-settings: cannot read hook list %s (%s)" % (path, e))
    hooks = decl.get("hooks") if isinstance(decl, dict) else None
    if not isinstance(hooks, list):
        sys.exit("claude-settings: %s must be an object with a \"hooks\" list" % path)
    for i, h in enumerate(hooks):
        ok = (isinstance(h, dict)
              and isinstance(h.get("event"), str) and h["event"]
              and isinstance(h.get("command"), str) and h["command"]
              and isinstance(h.get("matcher", ""), str)
              and set(h) <= {"event", "command", "matcher", "why"})
        if not ok:
            sys.exit("claude-settings: %s hooks[%d] needs string event+command "
                     "(optional matcher, why; no other keys)" % (path, i))
    return hooks


def apply_hooks(data, hooks):
    for h in hooks:
        add_hook(data, h["event"], h["command"], h.get("matcher"))


def selftest():
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "settings.json")
        # fresh file, then idempotent re-runs
        for _ in range(2):
            data = load(p)
            set_key(data, "cleanupPeriodDays", 180)
            add_hook(data, "Stop", "x hook")
            save(p, data)
        data = load(p)
        assert data["cleanupPeriodDays"] == 180
        assert len(data["hooks"]["Stop"]) == 1
        # existing keys survive
        data["model"] = "keep"
        save(p, data)
        data = load(p)
        set_key(data, "statusLine", {"type": "command"})
        save(p, data)
        assert load(p)["model"] == "keep"
        # a declared list applies idempotently, with matchers, alongside add-hook
        lst = os.path.join(d, "hooks.json")
        with open(lst, "w") as f:
            json.dump({"hooks": [
                {"event": "Stop", "command": "x hook", "why": "already wired"},
                {"event": "PreToolUse", "matcher": "Bash", "command": "y hook"},
            ]}, f)
        for _ in range(2):
            data = load(p)
            apply_hooks(data, load_hook_list(lst))
            save(p, data)
        data = load(p)
        assert len(data["hooks"]["Stop"]) == 1
        assert data["hooks"]["PreToolUse"] == [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "y hook"}]}]
        # a malformed list is refused before the settings file is touched
        with open(lst, "w") as f:
            json.dump({"hooks": [{"event": "Stop"}]}, f)
        try:
            load_hook_list(lst)
        except SystemExit:
            pass
        else:
            raise AssertionError("malformed hook list was accepted")
        # a broken file is refused and left as-is
        with open(p, "w") as f:
            f.write("{bad")
        try:
            load(p)
        except SystemExit:
            pass
        else:
            raise AssertionError("broken file was accepted")
        with open(p) as f:
            assert f.read() == "{bad"
    print("claude-settings: self-test passed")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--file")
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="op")
    s = sub.add_parser("set")
    s.add_argument("key")
    s.add_argument("value", help="a JSON value, e.g. 180 or '{\"type\":\"command\"}'")
    h = sub.add_parser("add-hook")
    h.add_argument("event")
    h.add_argument("command")
    h.add_argument("--matcher")
    a = sub.add_parser("apply-hooks")
    a.add_argument("hooks_json", help="a declared hook list (see module docstring)")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.file or not args.op:
        ap.error("--file and an operation are required")
    hooks = load_hook_list(args.hooks_json) if args.op == "apply-hooks" else None
    data = load(args.file)
    if args.op == "set":
        try:
            value = json.loads(args.value)
        except ValueError as e:
            ap.error("value is not valid JSON: %s" % e)
        set_key(data, args.key, value)
    elif args.op == "add-hook":
        add_hook(data, args.event, args.command, args.matcher)
    else:
        apply_hooks(data, hooks)
    save(args.file, data)


if __name__ == "__main__":
    main()
