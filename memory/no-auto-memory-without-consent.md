---
name: no-auto-memory-without-consent
description: Ethan wants to approve every memory; never auto-write — suggest instead
metadata:
  type: feedback
---

Ethan does not want Claude adding memories without his input. Do not autonomously
create or edit memory files on any box.

**Why:** Ethan wants to be the sole manager of his memory store and curate what
persists across sessions.

**How to apply:** Any time you would normally create or update an auto-memory, do NOT
write it. Instead, describe the memory you'd propose (name, type, content) and let
Ethan decide. Only write to the memory dir when he explicitly asks. This preference
itself was added at his explicit request.

**Where to edit:** once consent is given, the *where-to-write* rule is its own memory:
[[edit-in-repo]] — edit the owning repo's copy (shared in `dev-env`, box-local in this
machine's repo) and deploy via `install.sh`, never the live `~/.agents` copies.
Consent (this memory) and location (that one) are separate gates; clearing one does not
clear the other.
