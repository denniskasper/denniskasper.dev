# Generic bootstrap with a site-specific overlay

`init-server.sh` used to bake denniskasper-specific facts inline — the alert email, the URLs to monitor, the deploy targets, a Cloudflare token prompt — behind `dev`/`prod` conditionals. This refines ADR 0001's "one `init-server.sh` bootstraps either server": it is still one bootstrap script and one mental model, but everything tied to *a particular server or owner* now lives in an optional **site overlay**, leaving the bootstrap itself free of personal facts. The generic script does OS hardening, Docker Swarm, Dokploy, UFW/ufw-docker, Tailscale, and disk hygiene; the overlay (`site-init.sh`, run via `SITE_INIT` — a URL or a local path) owns URL monitoring, deploy reminders, and owner policy, receiving `SERVER_ROLE`/`ALERT_EMAIL`/`PUBLIC_IP`/`TAILSCALE_IP`/`NEW_USER` from the bootstrap. If no overlay is present the bootstrap skips it and still runs standalone.

## Considered Options

- **Keep everything inline with `dev`/`prod` conditionals (prior state).** One file, simplest to read top-to-bottom. Rejected: it bakes owner facts (alert email, monitored URLs, deploy targets) into a script that should be reusable on other servers or shareable; growing to a third server or handing the script to someone else means editing the supposedly "generic" parts. The 2026-05-24 dev clean-room run also showed several inline pieces were outright dead (the pre-created `POSTGRES_PASSWORD`/`CF_DNS_TOKEN` secrets Dokploy never uses), i.e. "inline everything" was accruing cruft.
- **A sourced config file (env/`.conf`) for the variable bits.** Externalizes values without touching behavior. Rejected: the host-specific parts are *logic*, not just values — "install this uptime check for these URLs" is a code path, not a setting. An executable overlay expresses that honestly; a flat config does not.
- **Separate per-server scripts (`init-dev.sh` / `init-prod.sh`).** Rejected: duplicates the entire hardened base, and drift between the two copies is inevitable. The value of ADR 0001 was one audited bootstrap.
- **Chosen: generic `init-server.sh` + optional site overlay via `SITE_INIT`.** The bootstrap holds zero owner/host facts; the overlay carries them and is delivered as a local file (repo clone) or fetched from a URL (single-file `curl` install).

## Consequences

- `init-server.sh` is now reusable on any fresh Ubuntu host — and shareable — without leaking personal configuration.
- Overlay delivery is now a real concern: a single-file `curl` install has no adjacent `site-init.sh`, so `SITE_INIT` accepts a URL to fetch one. If neither is supplied, host-specific setup (e.g. prod uptime monitoring) silently does not run — operators must pass `SITE_INIT` on a prod single-file install.
- Wildcard TLS and the Postgres password are deliberately **not** bootstrapped. Dokploy creates and owns `dokploy_postgres_password` (file-mounted, internal-only); Cloudflare DNS-01 for `*.denniskasper.dev` is configured in the Dokploy/Traefik UI, which persists the token across container recreations. Verified on the 2026-05-24 dev clean-room run.
- Three artifacts to keep coherent: `init-server.sh` (generic), `site-init.sh` (this project's overlay), and `site-init.example.sh` (the template/contract).
- Still aligned with ADR 0001 — the same bootstrap provisions either server — but owner/host specifics live in the overlay rather than inline role conditionals.
