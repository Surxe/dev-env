---
name: no-email-in-repos
description: "never commit email addresses to any repo; they live in Ethan's config set manually"
metadata:
  type: feedback
---

Email addresses are never checked in to any repository. They should always live in
Ethan's config, set manually by him.

**Why:** Keeping emails out of the git tree avoids leaking them via public repos and
keeps them as machine-local config rather than shared source.

**How to apply:** Don't hardcode or commit any email address (git user.email, config
files, scripts, docs). If a repo needs to reference where an email is configured,
document its *location* in the owning repo rather than the value itself.

**Exception — GitHub noreply addresses:** `ID+user@users.noreply.github.com` addresses
are public-by-design (GitHub exposes them on every commit) and carry no private
mailbox, so they MAY be committed. This is why dev-env's `deploy_gitconfig` (in
`lib/deploy-claude.sh`) hardcodes Surxe's noreply
(`119145352+Surxe@users.noreply.github.com`) as dev's git author email so credit
routes to the `Surxe` account (primary author on direct pushes; co-author on
squash-merged PRs). Real/personal addresses (e.g. `*@gmail.com`) remain forbidden.
