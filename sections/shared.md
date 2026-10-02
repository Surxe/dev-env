<!-- SECTION: shared -->
<!-- From dev-env/sections/shared.md — identical on every box. Edit it there, not in a machine repo. -->

## Shared across Ethan's boxes (from `dev-env`)

Ethan runs agents as `dev` on two boxes: the **workstation** (`ethan-debian`) and the
**home-server** (Proxmox host). A SessionStart hook prints the active hostname; the
`active-box` memory maps it to the box.

- **Where a file lives is what it is.** `dev-env` = shared by both boxes; `my-system` =
  workstation only; `home-server` = server host only; `valheim-server` = the Valheim
  server on the server box. Edit config in the repo that owns it and deploy with that
  repo's `install.sh`; never edit the live copies under `~/.agents` (or the `~/.claude` /
  `~/.dsh` symlinks into them) by hand.
- **`~/.agents` is the neutral root** both Claude Code and the DeepSeek Harness read:
  - `~/.agents/AGENTS.md` — this file, symlinked to `~/.claude/CLAUDE.md` and
    `~/.dsh/AGENTS.md`. It is **generated**: the box's machine repo assembles it from its
    own blueprint (box-specific prose), the list of repos cloned on the box, and this
    shared section (`dev-env/sections/shared.md`).
  - `~/.agents/memory/` — memory notes + the `MEMORY.md` index (symlinked into
    `~/.claude/projects/<project>/memory/`; the DeepSeek Harness reads a rendered copy
    under `~/.dsh/memory/` via the `memory-standard` plugin). Read the index, then load
    only the note you need.
  - `~/.agents/skills/` — skills (symlinked to `~/.claude/skills/`), shared ones from
    `dev-env` plus the box's own.
- **Working rules on every box:**
  - No secrets in repos — document only where they live. Don't touch SSH keys,
    passwords, or SMTP/API tokens.
  - Commit/push only when asked; branch off the default branch for changes.
  - New repos/projects go under `/srv/dev/repos`.
