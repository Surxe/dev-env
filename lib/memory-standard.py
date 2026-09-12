#!/usr/bin/env python3
"""memory-standard.py — render Claude-format memory notes into the
`dsh-memory-standard` (mm) layout for the DeepSeek Harness.

The DeepSeek Harness has no native MEMORY.md / memories support; the
`JohnXu22786/memory-standard` plugin supplies it. That plugin reads one root:

    <root>/MEMORY.md            index (## <topic> sections)
    <root>/memories/<topic>.md  detail notes

Our memories are authored as Claude Code memory files (YAML frontmatter with
`name` / `description` / `metadata.type`). This helper converts them: it turns
each note into `memories/<topic>.md` and (re)generates the matching `## <topic>`
section in `<root>/MEMORY.md`, leaving every section it does not own untouched
so the shared (dev-env) and box-local (machine repo) slices can coexist.

Dependency-free (Python stdlib only).

Usage:
    memory-standard.py render --src <dir> --dst <dsroot> [--memory-id <id>]

Idempotent: re-running with the same source rewrites only the topics it owns.
"""

import argparse
import datetime
import os
import re
import sys

SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
MEM_KIND = "note"
MEM_VERSION = 1
INDEX_CAPS = "200 lines / 25600 bytes"


def log(msg):
    print("  %s" % msg, file=sys.stderr)


def parse_frontmatter(text):
    """Return (meta, body) when the file opens with a `---` YAML block, else
    (None, text). `meta` holds only the scalar fields we need."""
    if not text.startswith("---"):
        return None, text
    end = text.find("\n---", 3)
    if end == -1:
        return None, text
    block = text[3:end]
    body = text[end + 4:].lstrip("\n")
    meta = {}

    def scalar(key, default=None):
        # quoted "…" / '…' or a bare rest-of-line value
        m = re.search(r"^%s:\s*(.*)$" % re.escape(key), block, re.M)
        if not m:
            return default
        v = m.group(1).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1].replace("\\" + v[0], v[0]).replace("\\\\", "\\")
        return v or default

    meta["name"] = scalar("name")
    meta["description"] = scalar("description")
    meta["type"] = scalar("type")  # `type:` may sit under `metadata:`; regex matches either
    return meta, body


def slugify(name, fallback):
    s = (name or fallback).strip()
    s = re.sub(r"[^A-Za-z0-9._-]+", "-", s).strip(".-")
    if not s:
        s = fallback
    if not SLUG_RE.match(s) or len(s) > 64:
        s = re.sub(r"[^A-Za-z0-9._-]+", "-", s).strip(".-")
    return s or "memory"


def render_note(topic, memory_id, body):
    return (
        "# %s\n\n"
        "> mm-id: %s\n"
        "> mm-version: %d\n"
        "> mm-kind: %s\n"
        "> mm-topic: %s\n"
        "> mm-file: memories/%s.md\n\n"
        "%s" % (topic, memory_id, MEM_VERSION, MEM_KIND, topic, topic, body.rstrip() + "\n")
    )


def render_index_section(topic, summary, tags, memory_id, mtime):
    lines = ["## %s" % topic]
    if summary:
        lines.append("- **summary:** %s" % summary.replace("\n", " ").strip())
    if tags:
        lines.append("- **tags:** %s" % ", ".join(tags))
    lines.append("- **file:** memories/%s.md" % topic)
    if mtime:
        stamp = datetime.datetime.fromtimestamp(mtime, tz=datetime.timezone.utc)
        lines.append("- **updated:** %s" % stamp.strftime("%Y-%m-%dT%H:%M:%SZ"))
    return "\n".join(lines) + "\n"


def ensure_header(index, memory_id):
    if not index.strip():
        return (
            "# MEMORY.md\n\n"
            "Memory Standard Index — hand-load priority; managed by dsh-memory-standard.\n"
            "Hard caps: %s. Over budget => rewrite (never truncate).\n\n"
            "> mm-id: %s\n"
            "> mm-version: %d\n"
            "> mm-kind: index\n"
            "> mm-caps: %s\n\n" % (INDEX_CAPS, memory_id, MEM_VERSION, INDEX_CAPS)
        )
    if not index.lstrip().startswith("# "):
        index = "# MEMORY.md\n\n" + index.lstrip()
    return index


def rewrite_index(index, entries, memory_id):
    """Remove any existing `## <topic>` sections for our topics, then append
    fresh ones. Other sections are preserved verbatim."""
    index = ensure_header(index, memory_id)
    topics = {e["topic"] for e in entries}
    lines = index.split("\n")
    out = []
    skip = False
    for ln in lines:
        if ln.startswith("## "):
            skip = ln[3:].strip() in topics
            if skip:
                continue
        if not skip:
            out.append(ln)
    result = "\n".join(out).rstrip("\n")
    if entries:
        result = result + "\n\n" + "\n\n".join(
            render_index_section(e["topic"], e["summary"], e["tags"], memory_id, e["mtime"]) for e in entries
        ).rstrip("\n") + "\n"
    return result + "\n"


def read_notes(src):
    notes = []
    if not os.path.isdir(src):
        return notes
    for fn in sorted(os.listdir(src)):
        if not fn.endswith(".md"):
            continue
        if fn == "MEMORY.md" or fn.startswith("MEMORY."):
            continue
        path = os.path.join(src, fn)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()
        meta, body = parse_frontmatter(text)
        if meta is None:
            meta = {}
        topic = slugify(meta.get("name"), fn[:-3])
        summary = (meta.get("description") or "").strip()
        tags = []
        t = (meta.get("type") or "").strip()
        if t:
            tags.append(t)
        notes.append({"topic": topic, "summary": summary, "tags": tags, "body": body,
                      "mtime": os.path.getmtime(path), "path": path})
    return notes


def cmd_render(args):
    src = args.src
    dst = args.dst
    memory_id = args.memory_id or "local"
    notes = read_notes(src)
    if not notes:
        log("memory-standard: no notes under %s" % src)
        return 0
    memories_dir = os.path.join(dst, "memories")
    os.makedirs(memories_dir, exist_ok=True)
    for n in notes:
        out = os.path.join(memories_dir, n["topic"] + ".md")
        with open(out, "w", encoding="utf-8") as f:
            f.write(render_note(n["topic"], memory_id, n["body"]))
        log("dsh memory -> %s" % out)
    index_path = os.path.join(dst, "MEMORY.md")
    existing = ""
    if os.path.exists(index_path):
        with open(index_path, encoding="utf-8") as f:
            existing = f.read()
    with open(index_path, "w", encoding="utf-8") as f:
        f.write(rewrite_index(existing, notes, memory_id))
    log("dsh memory index -> %s (%d topics)" % (index_path, len(notes)))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="memory-standard.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("render", help="render a Claude memory dir into an mm root")
    r.add_argument("--src", required=True)
    r.add_argument("--dst", required=True)
    r.add_argument("--memory-id", default="local")
    r.set_defaults(func=cmd_render)
    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
