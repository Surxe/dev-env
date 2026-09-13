# dev-env

The **shared dev-environment layer** for Ethan's boxes. It holds the portable
"dev ergonomics" that should be identical everywhere Claude Code runs as `dev` —
and nothing box-specific. Each machine repo consumes it as a sibling clone and
installs it with one step.

## The three-bucket model (location = classification)

Every shareable item (skill, memory, shell fragment, bin) belongs to exactly one
bucket, and **the repo it lives in *is* its bucket** — no tags, no manifest, can't
drift:

| Bucket | Lives in | Installs to |
| --- | --- | --- |
| **shared** | **this repo (`dev-env`)** | every box |
| home-pc only | `my-system` | the workstation |
| home-server only | `home-server` | the server |

The machine repos keep owning and installing all their box-local content exactly as
before; `dev-env` owns only the shared slice.

## What's shared here

- `skills/` — `pr`, `merged`, `brainstorm`. Installed to `~/.agents/skills`, which
  both Claude Code (via a `~/.claude/skills` symlink) and the DeepSeek Harness
  (native `user-agents` root) read.
- `bashrc.d/10-agents.sh` — the `cc` launcher (Claude) + the `ds` launcher
  (DeepSeek Harness), exporting `DEEPSEEK_API_KEY` from `~/.config/deepseek/env`
  into every interactive dev shell at startup, + the mouse-release export.
- `statusline.py` — the Claude status line (wired into `settings.json`).
- `dsh/` — the DeepSeek Harness (dsh-tui) status bar: a status contribution
  (`statusbar.mjs`) mounted through the profile's `cordis.patch.yml`, rendering a
  single dim line `host · model · ctx% · repo` above the prompt — the dsh-tui
  parity of `statusline.py` (dsh has no 5h/wk rate-limit windows, and its scalar
  `ctx.tuiStatus.set` seam is monochrome, so those differ from the Claude bar).
  Installed by `deploy_dsh_statusbar`; won't clobber a hand-edited
  `cordis.patch.yml`.
- `memory/` — universal memory notes + `MEMORY.shared.md` (the index fragment merged
  into each box's `MEMORY.md`). The same notes are also rendered into the
  `memory-standard` (mm) layout for the DeepSeek Harness at `~/.dsh/memory`.
  Git identity (`Surxe-dev`) is set by the engine.

## DeepSeek API key

`DEEPSEEK_API_KEY` is **not** stored in this repo. It lives in
`~dev/.config/deepseek/env` (single line `DEEPSEEK_API_KEY=...`, mode 0600,
dev-owned) on each box, and `bashrc.d/10-agents.sh` exports it into every
interactive dev shell at startup (`ds()` re-sources it as a fallback at launch).
To set it on a box:

```
install -d -m 700 ~/.config/deepseek
printf 'DEEPSEEK_API_KEY=sk-...\n' > ~/.config/deepseek/env
chmod 600 ~/.config/deepseek/env
```

On a headless box running dsh under systemd, use `EnvironmentFile=` pointing at
that file instead of a launcher (see the `home-server` repo's `docs/`).

## Install

```
./install.sh [--host workstation|home-server]
```

`--host` autodetects from `hostname` when omitted. The script **re-execs itself as
`dev`** (via `sudo -u dev` / `runuser`) when run by ethan or root, then deploys into
`~dev/.agents` (the neutral agent root) and symlinks the Claude-specific paths into
`~dev/.claude`, plus `~dev/.bashrc.d`, `~dev/.gitconfig`, and the DeepSeek Harness
memory (`~dev/.dsh/memory` + the `memory-standard` plugin). Copy-based, additive,
idempotent. Each machine repo calls it as one step of its own `install.sh`.

## Per-box config & the `.local` override pattern

`hosts/<name>.env` is the box's profile, sourced by the installer:

- `PROJECT` — the Claude project dev's memories live under (`srv-dev` / `home-dev`).
- `EXCLUDE` — space-separated shared items this box opts out of (default: include all).
- **Override vars** — values for *parameterized* shared items.

When a shared item would differ between boxes **only** in box-specific values
(paths, project name), it is **not forked** — it stays a single canonical file with
`{{VAR}}` placeholders, and each box fills them from its `hosts/<name>.env`. The
engine renders placeholders before copying and **fails loudly on any unresolved
`{{VAR}}`**, so a half-rendered file is never deployed. Example: the single
`memory/edit-in-repo.md` renders to the my-system paths on the workstation and the
`home-dev` paths on the server — replacing what used to be two near-duplicate notes.

## Engine

`lib/deploy-claude.sh` is the reusable, sourced engine (`render_tree`, `deploy_skills`,
`deploy_memory`, `deploy_dsh_memory`, `deploy_dsh`, `deploy_bashrc`,
`deploy_gitconfig`, `deploy_statusline`, plus the `_ensure_symlink` helper that
wires `~/.claude` onto the neutral `~/.agents` root). It generalizes the dev-tier
installers that lived in `my-system/users/installers/`. `lib/memory-standard.py`
renders Claude-format memory notes into the `memory-standard` (mm) layout the
DeepSeek Harness plugin reads. Set `DEVENV_HOME_OVERRIDE` to redirect all writes to
a throwaway tree for testing.

## Prerequisites on a consuming box

`pr`/`merged` depend on cross-repo tools that must be present for the skills to work:
`gh` authenticated as `dev`, a `dev` git identity (this engine sets it), and the
`todo` CLI on `PATH`.
