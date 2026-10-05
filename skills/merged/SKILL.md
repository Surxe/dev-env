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
every box they deploy to. `sync-box.sh` (a sibling of this file) does that — on
each *other* box it checks the clone is safe to deploy into (on its default
branch, no tracked changes, no WRF pipeline run active for pipeline repos),
pulls it, re-checks out its vendored design submodule at the recorded commit
(a submodule that is merely stale doesn't count as a tracked change), syncs its
`.venv` from `requirements.txt` when it has one, and on the
server runs its installer if it has one (workstation installs are left to
Ethan). Repos that aren't box repos, or that deploy only to the box you're on,
are a no-op.

The full policy — which repos, which boxes, which install command — lives
**entirely in the script**, and `merged.sh` runs it for every repo it cleans.
**Never decide yourself whether a repo is a box repo or needs syncing**, and
never report one as synced or skipped except by reading the script's output.

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

## Step 2 — Run `merged.sh` (one turn)

Cleanup and cross-box sync run as **one script call** covering every repo the
user named, so the whole skill is a single tool turn and the sync cannot be
skipped. Do not break it into separate `git`/`gh`/`sync-box.sh` calls.

```bash
~/.agents/skills/merged/merged.sh /srv/dev/repos/<repo> [/srv/dev/repos/<repo2> ...]
```

Per repo it switches to the default branch, fetches/pulls, and deletes the
feature branch only when GitHub reports its PR `MERGED` (`-D`, so squash merges
work); a repo already on its default branch is just pulled. Then it **always**
runs `sync-box.sh` for that repo — including the already-on-default case. Each
repo prints its own `RESULT:`/`STOP:` lines, and the run ends with a `SUMMARY:`
line; the exit code is non-zero if any repo hit a `STOP:`.

On any `STOP:` line, **halt and tell Ethan** what it says — don't delete
anything, retry, or improvise around it (e.g. a server clone on a feature branch
or with local edits is reported, not fixed).

## Step 3 — Report

Briefly state what happened per repo, reading off `merged.sh`'s `RESULT:`/`STOP:`
lines (quote the sync line as printed):
todo closed (with id) if any, now on the default branch, feature branch deleted,
tree up to date, and any cross-box sync done or skipped. If a `STOP:` appeared
at any step, report it and halt. No emojis.
