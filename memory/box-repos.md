---
name: box-repos
description: "Three config repos under /srv/dev/repos: dev-env = shared (both boxes), my-system = workstation, home-server = home server"
metadata:
  type: reference
---

Ethan's box config lives in three repos under `/srv/dev/repos/`:

- **dev-env** — shared across both boxes: portable skills, memory, `cc`/`ds`
  launchers, `statusline.py`, `bashrc.d`. Deployed by `dev-env/install.sh`.
- **my-system** — workstation-local: KDE shortcuts, shell aliases/functions,
  user-specific skills/statusbars. Deployed by its `install.sh`.
- **home-server** — home-server-local: Proxmox host + Valheim VM config.
  Deployed by its `install.sh`.

Edit shared items in `dev-env`, box-local items in that box's repo, then deploy
via `install.sh` — see [[edit-in-repo]] and [[repos-location]].
