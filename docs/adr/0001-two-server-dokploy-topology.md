# Two-server Dokploy topology with dev as playground

Both VPSes — `denniskasper.com` (Strato VPS PA-S178, IP `87.106.73.236`) and `denniskasper.dev` (Hetzner Cloud CX22, Nuremberg) — run **Dokploy** as their only orchestrator. Prod hosts the public homepage and the production OpenLeprechaun instance (`leprechaun.denniskasper.com`); dev is a playground for preview deploys, experiments, and side projects under `*.denniskasper.dev`. A single `init-server.sh` bootstraps either server from a clean Ubuntu 26.04 LTS install — same script, same stack, same mental model, despite the different hosting providers.

## Considered Options

- **Bare-metal nginx + systemd on prod (current state for the homepage).** Lower RAM, smaller attack surface. Rejected: adding even one more app (OpenLeprechaun) means two deployment styles to maintain, and `init-server.sh` already needs rewriting to support Docker either way. The marginal cost of running Dokploy for the homepage is ~1.5 GB RAM, which the prod VM has to spare.
- **k3s / lightweight Kubernetes on both servers.** More powerful, industry-standard. Rejected: single-operator setup, single-user app, no horizontal scaling needs. The ops overhead of Kubernetes is dramatically higher than Dokploy for zero functional gain at this scale.
- **Managed PaaS (Vercel, Fly.io, Railway).** Zero ops. Rejected: OpenLeprechaun stores German tax data and must remain self-hosted on infrastructure I control; the homepage is also a "things I run" exercise on principle.
- **Staging-mirror discipline for dev (deploy `development` branch to dev, promote to prod).** Rejected: as a single-user tax tool with manual approval gates in the Dokploy UI, the marginal value of a permanent staging instance doesn't justify pinning dev's role. Dev as a free playground is more valuable for experimentation; one-off preview deploys cover the staging use case when actually needed.

## Consequences

- The prod VM runs Dokploy's overhead (Traefik + Postgres + Redis + Dokploy app) just to host one static site and one self-hosted app. Acceptable on the current hardware.
- "Dev = playground" means there is no automated pre-flight check before a prod deploy. The manual-approval gate in the Dokploy UI is the only safety net; if a non-trivial change needs validation, the workflow is to spin up an ad-hoc preview deploy on dev first.
- Tax data lives on prod alongside the public homepage. The blast radius of a prod-server compromise includes both. Mitigations: Dokploy's per-app isolation (Docker networks), separate domain (`leprechaun.` subdomain not advertised publicly), TLS everywhere via Traefik.
- A single `init-server.sh` means changes affect both servers' bootstrap. Test on dev first when modifying.
