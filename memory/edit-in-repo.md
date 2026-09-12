---
name: edit-in-repo
description: Writing/editing ANY Claude memory or skill -> edit the owning repo's copy (shared items in dev-env, box-local items in this box's machine repo), never the live ~/.claude copy; deploy via install.sh
metadata:
  type: feedback
---

Claude config (memory notes, `MEMORY.md`, skills, the `cc` launcher, statusline) is
**source-controlled, not authored in the live store**. It lives in one of two layers,
and you edit it in the layer that owns it:

- **Shared across boxes** -> `dev-env` (`/srv/dev/repos/dev-env/`): `skills/`,
  `memory/`, `bashrc.d/`, `statusline.py`. Deployed to every box by
  `dev-env/install.sh`. This note itself is a shared memory — you are reading it from
  the live dir only because it was authored in `dev-env` and installed.
- **Box-local to this machine ({{MACHINE_REPO}})** -> box-local memories live in
  `{{MEMORY_REPO_DIR}}/` (Claude project `{{PROJECT}}`), deployed by `{{INSTALL_CMD}}`.

Never edit the live `~dev/.claude/...` copies directly: that path is a **deployment
target**, refreshed (copy-based) on the next install, so a direct edit is overwritten
and lost from git.

**Why:** config-as-code — version-controlled, reviewed, rebuildable. A note that
exists only in `~/.claude` is invisible to git and dies on rebuild/reinstall. The repo
copy also carries the verification/consent boundary; writing straight to live bypasses
it. Same principle as [[no-symlink-repo-to-home]].

**How to apply:** the moment you are about to create or edit ANY memory or skill —
including in response to an explicit "add a memory" request — decide the layer first
(shared vs box-local), write it in that repo, add its index line to the matching
`MEMORY.md` (the shared block for `dev-env` items; `{{MEMORY_REPO_DIR}}/MEMORY.md` for
box-local ones), and do NOT touch the live copies. Do not auto-commit; ask Ethan, then
remind him to deploy (`dev-env/install.sh` for shared, `{{INSTALL_CMD}}` for box-local).
This is the *where-to-write* rule; [[no-auto-memory-without-consent]] is the separate
*whether-to-write* rule — satisfying consent does NOT exempt you from this.
