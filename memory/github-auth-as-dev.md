---
name: github-auth-as-dev
description: "As the dev user, gh is now persistently authenticated (hosts.yml) — call gh directly, no GH_TOKEN needed"
metadata:
  type: reference
---

Running as the `dev` user, `gh` is **persistently authenticated** as `Surxe-dev`
via `~/.config/gh/hosts.yml`. Just call `gh <cmd>` directly — **no `GH_TOKEN`, no
`git credential fill` pipeline**. This is the clean path for the [[pr-skill]],
`/merged`, and any `gh` call as dev.

The old inline-`GH_TOKEN` workaround is retired. It only existed because the
previous PAT lacked the `read:org` scope, so `gh auth login --with-token`
refused to persist it. The current PAT has `read:org`, so a one-time
`gh auth login --with-token` persisted it cleanly.

Recovery if `~/.config/gh/hosts.yml` is ever lost (re-persist from the token in
the git credential store):

```
tok=$(sed -n 's#.*://[^:]*:\([^@]*\)@.*#\1#p' ~/.git-credentials)
printf '%s' "$tok" | gh auth login --with-token
```

The git `credential.helper=store` (`~/.git-credentials`) is unchanged and still
handles plain `git push`/`pull`.
