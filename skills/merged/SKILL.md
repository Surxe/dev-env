---
name: merged
description: >-
  Post-merge cleanup after a /pr is merged on GitHub. Run once Ethan has merged
  the PR: closes the initiating todo, switches the local checkout back to the
  default branch, fetches and pulls, deletes the now-merged local feature
  branch, and syncs a merged box repo to the other box (pull over SSH; run
  install.sh on the server only). Merge-gated and idempotent. Use whenever the
  user runs /merged or asks to clean up after a PR merged.
model: haiku
---

# Post-merge cleanup

The companion to `/pr`. `/pr` opens the PR and leaves the merge to Ethan; this
skill does the local cleanup afterward. It is the same-session follow-up: the PR
is opened and merged within one session, so the initiating todo id (if any) is
known from conversation — no persisted linkage.

**Safe to re-run.** Every step is idempotent, and no branch is deleted unless
GitHub confirms its PR is merged.

This skill is pinned to `haiku` via frontmatter: after the merge gate it is pure
deterministic plumbing — git cleanup plus the cross-box sync, both script-driven
with no judgment — so it does not warrant a large model. Keep it that way — if
you add real decision-making here, revisit the pin.

## Cross-box sync

Some repos under `/srv/dev/repos` are "box repos": a merge to them must land on
every box they deploy to. `sync-box.sh` (a sibling of this file) does that — it
SSHes to each *other* box, pulls the repo, and on the server also runs its
installer if it has one (workstation installs are left to Ethan). Repos that
aren't box repos, or that deploy only to the box you're on, are a no-op.

The full policy — which repos, which boxes, which install command — lives
**entirely in the script**. Don't restate or second-guess it here: just run it
(Step 3) and read its `RESULT:`/`STOP:` line.

## Auth — same as `/pr`

`gh` is persistently authenticated for `dev` as `Surxe-dev` (via
`~/.config/gh/hosts.yml`), so call `gh` directly — no `GH_TOKEN`. If a `gh` call
fails with an auth error, re-persist from the git credential store:

```
tok=$(sed -n 's#.*://[^:]*:\([^@]*\)@.*#\1#p' ~/.git-credentials)
printf '%s' "$tok" | gh auth login --with-token
```

If the token is empty or login still fails, stop and tell Ethan.

## Step 1 — Close the initiating todo

If this session's work maps to a todo item, run it done **immediately, no
confirmation**. That mapping can arise several ways:

- the session was initiated with `!todo show <id>`;
- Ethan added the todo item at the start of the session and said to implement it;
- a todo id was referenced along the way as the thing this feature addresses.

Then:

```
todo done <id>
```

If no todo id is in play, skip this step silently. (House rule
`todo-command-no-action` says todo calls are normally Ethan's own logging and not
requests to act — this skill is the explicit exception, because closing the
initiating todo is part of what Ethan asked `/merged` to do.)

## Step 2 — Run the cleanup script (one turn)

Everything else — branch detection, the already-clean short-circuit, the merge
gate, and the actual cleanup — runs as a **single guarded script** so the whole
cleanup is one tool turn rather than five. Do not break it back into separate
`git`/`gh` calls; the point of the one-shot is to avoid re-billing the (large,
end-of-session) context on every step.

```bash
set -euo pipefail

# Default branch: origin/HEAD leaf, falling back to gh.
default=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's#^refs/remotes/origin/##')
[ -n "${default:-}" ] || default=$(gh repo view --json defaultBranchRef \
  -q .defaultBranchRef.name)
current=$(git branch --show-current)

# Already-clean short-circuit: on default, nothing to delete.
if [ "$current" = "$default" ]; then
  git fetch --prune
  git pull --ff-only
  echo "RESULT: already on $default, nothing to clean"
  exit 0
fi

# Merge gate — never delete unmerged local work.
state=$(gh pr view "$current" --json state -q .state 2>/dev/null || echo NONE)
if [ "$state" != "MERGED" ]; then
  echo "STOP: PR for '$current' is '$state' (need MERGED). Not deleting."
  exit 1
fi

# Clean up. -D (not -d): the merge is gated via GitHub above, and -d would
# wrongly refuse after a squash merge (local commits aren't ancestors of
# $default). --prune drops the remote ref GitHub auto-deleted on merge.
git switch "$default"
git fetch --prune
git pull --ff-only
git branch -D "$current"
echo "RESULT: merged '$current' cleaned; now on $default, up to date"
```

If the script prints a `STOP:` line (PR not merged, or no PR found for the
branch), **halt and tell Ethan** — do not delete anything or improvise.

## Step 3 — Sync the other box (one turn)

After Step 2's script prints a `RESULT:` line (i.e. not `STOP:`), run the sync
helper once, passing the repo directory that was just cleaned:

```bash
~/.agents/skills/merged/sync-box.sh /srv/dev/repos/<repo>
```

It derives the current box from `hostname`, skips any repo that is not a box
repo or that deploys only to this box, and otherwise pulls — and on the server
also runs `install.sh` — on each other box. Read off its `RESULT:`/`STOP:` line.
On `STOP:`, tell Ethan — the remote box was not fully synced; do not retry
silently or improvise.

## Step 4 — Report

Briefly state what happened, reading off the scripts' `RESULT:`/`STOP:` lines:
todo closed (with id) if any, now on the default branch, feature branch deleted,
tree up to date, and any cross-box sync done or skipped. If a `STOP:` appeared
at any step, report it and halt. No emojis.
