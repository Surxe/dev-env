---
name: todo-command-no-action
description: "Ethan's `todo` CLI calls are logging, not requests — don't act or spend tokens unless asked"
metadata:
  type: feedback
---

When Ethan runs the `todo` CLI in-session (e.g. `!todo add ...`, `todo list`, `todo show`,
`todo classify`), it is just him capturing/managing his todo inbox — NOT a request for me
to do anything. Do not investigate, plan, or spend tokens reacting to it. Give at most a
minimal acknowledgment, or ideally stay silent.

Only take action when Ethan explicitly asks in a separate prompt, or a prior prompt already
told me to act on that todo.

**Why:** Ethan uses `todo` as a personal capture tool that happens to be visible to me;
auto-reacting (e.g. offering to fix a bug the moment he captures it, or investigating on a
`list`) wastes tokens and is presumptuous.

**How to apply:** Treat `todo ...` command output like passive background context. Wait for
an explicit ask before doing work. Related: [[no-auto-memory-without-consent]].
