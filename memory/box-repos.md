---
name: box-repos
description: "Config repos under /srv/dev/repos: dev-env = shared (both boxes), my-system = workstation, home-server = server host, valheim-server = the Valheim server on the server box"
metadata:
  type: reference
---

Ethan's box config lives in four repos under `/srv/dev/repos/`:

- **dev-env** — shared across both boxes: portable skills, memory, `cc`/`ds`
  launchers, `statusline.py`, `bashrc.d`. Deployed by `dev-env/install.sh`.
- **my-system** — workstation-local: KDE shortcuts, shell aliases/functions,
  user-specific skills/statusbars. Deployed by its `install.sh`.
- **home-server** — server host: Proxmox/wifi, host backups, the todo hub.
  Deployed by its `install.sh`.
- **valheim-server** — the modded Valheim server on the server box (VM 100):
  Docker/mod config, VM tooling, its systemd feeds, and its own skills + memory.
  A sibling clone; `home-server/install.sh` runs its `install.sh` too.

Edit shared items in `dev-env`, box-local items in that box's repo, then deploy
via `install.sh` — see [[edit-in-repo]] and [[repos-location]].
