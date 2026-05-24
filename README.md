# denniskasper.dev

A personal playground for experimenting with web development, self-hosted tooling, and infrastructure.

## Server bootstrap

`init-server.sh` provisions a hardened Dokploy server on a fresh Ubuntu LTS VPS
(OS hardening, Docker Swarm, Tailscale, UFW, fail2ban, Dokploy). It is generic
and reusable — it holds no facts about any specific server.

Anything host- or owner-specific (which URLs to monitor, app deploy steps) lives
in an **optional site overlay** that the bootstrap runs near the end, if present:

- Point `SITE_INIT` at an overlay — a **URL or a local path**. It defaults to a
  `site-init.sh` beside `init-server.sh` (present on a repo clone, absent on a
  single-file `curl`). If none is found it's skipped, so `init-server.sh` runs
  standalone on any box.
- The overlay receives `SERVER_ROLE`, `ALERT_EMAIL`, `PUBLIC_IP`, `TAILSCALE_IP`,
  and `NEW_USER` as environment variables.

`site-init.sh` is this project's live overlay; `site-init.example.sh` is a
sanitized template — copy it and edit for a new server.
