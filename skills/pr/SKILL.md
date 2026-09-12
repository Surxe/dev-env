---
name: pr
description: >-
  Open a GitHub pull request from this workstation as the dev user. gh is
  persistently authenticated for dev, so it just works; creates a feature
  branch when on main/master/dev, commits outstanding work, and opens a
  non-automerge PR with a brief description. Use whenever the user wants to open
  or create a PR / pull request, or runs /pr.
---

# Open a pull request

Lightweight PR flow for this box. It is deliberately thin: no enforced review
policy, no mandated PR format. A review of the change is assumed to have already
happened — this skill just gets the change onto a branch and into a PR.

## Auth

`gh` is persistently authenticated for `dev` as `Surxe-dev` (via
`~/.config/gh/hosts.yml`), so just call `gh` directly — no `GH_TOKEN`, no
`git credential fill`. If a `gh` call ever fails with an auth error, the login
has been lost; re-persist it from the token in the git credential store:

```
tok=$(sed -n 's#.*://[^:]*:\([^@]*\)@.*#\1#p' ~/.git-credentials)
printf '%s' "$tok" | gh auth login --with-token
```

If that token is empty or the login still fails, stop and tell the user.

## Step 1 — Check the branch

`git branch --show-current`:

- **`main` / `master` / `dev`** — you are on a base branch. Create a feature
  branch first (see Step 3), then commit onto it. Name it lowercase and
  dash-separated (`x-y-z`); a `feat-`/`fix-` style prefix is a *suggestion*, not
  required — pick what fits.
- **any other name** — treat it as an already-purposed feature branch and work
  on it as-is. Only ask the user to clarify if that assumption looks wrong.

## Step 2 — Check for unrelated changes → STOP if found

Look at `git status`. If the working tree contains changes **unrelated to this
session's work**, assume it is unintentional — most often the user has a second
session running against the same repo at the same time.

**Halt immediately. Do not commit, branch, or PR.** Tell the user what unrelated
files you see and wait until they say proceed (typically after the other session
finishes). You may suggest how to proceed in the meantime. This is the **only**
confirmation gate on the commit path.

## Step 3 — Get everything committed

Hard gate: **all** intended changes must be committed before the PR is created.
No confirmation is needed to commit (only the unrelated-changes gate above pauses
for the user).

- **Was on a base branch (main/master/dev):** create the feature branch first,
  then commit everything in a single commit.
- **Already on a feature branch:** just commit any remaining changes onto the
  existing series.

Then `git push -u origin <branch>` (the `store` credential helper handles auth).

## Step 4 — Verification gate before the PR

- **Pure doc / config changes:** no confirmation — proceed straight to the PR.
- **Changes that affect an application or a downstream location:** the user must
  have confirmed the change actually works. If that is already evident from the
  session, proceed; if not, ask once before opening the PR.

Never kick off a Claude-run code review as part of this skill unless the user
explicitly asks for one.

## Step 5 — Create the PR

```
gh pr create --title '<title>' --body '<body>'
```

- Let `gh` auto-detect the base branch — no need to compute main-vs-master.
- **Description:** brief; briefer still for small changes; freeform style.
- **Do not** add drafts, reviewers, or labels unless the user asks.
- **Never automerge.** The user's approval is always required to merge.
- **No** "Generated with Claude Code" trailer, no "assisted by" footer, no
  emojis — just the description.

Report the PR URL back to the user.

## Notes

- The commit `Co-Authored-By:` trailer is a harness default and stays; the "no
  stamp" rule applies to the PR body, not the commit trailer.
- Committing the change into its own repo (e.g. `my-system`) follows that repo's
  git rules — commit only when asked.

## After the PR merges

Once Ethan has merged the PR, the local cleanup is handled by the **`/merged`**
skill — it closes the initiating todo (if any), switches back to the default
branch, fetches/pulls, and deletes the local feature branch. Point Ethan at
`/merged` rather than doing the cleanup ad hoc here.
