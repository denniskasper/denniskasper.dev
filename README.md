# denniskasper.dev

A personal playground for experimenting with web development, self-hosted tooling, and infrastructure.

## Server bootstrap

`init-server.sh` provisions a hardened Dokploy server on a fresh Ubuntu LTS VPS
(OS hardening, Docker Swarm, Tailscale, UFW, fail2ban, msmtp, Dokploy). It is
generic and reusable — it holds no facts about any specific server. Every
host-specific value is an input: the username, the SSH public key, the Tailscale
hostname, the auth key, and the alert mailbox.

Anything host- or owner-specific in *behaviour* (app deploy steps, owner policy)
can live in an **optional site overlay** that the bootstrap runs near the end:

- Point `SITE_INIT` at an overlay — a **URL or a local path**. It defaults to a
  `site-init.sh` beside `init-server.sh`. If none is found it's skipped, so
  `init-server.sh` runs standalone on any box.
- The overlay receives `ALERT_EMAIL`, `PUBLIC_IP`, `TAILSCALE_IP`, `TS_HOSTNAME`
  and `NEW_USER` as environment variables.

**This repo ships no overlay today.** The one it used to carry held an on-box
uptime cron and a Cloudflare tunnel connector; both are gone (see
[Monitoring](#monitoring) and [Deploys](#deploys-ci-over-the-tailnet)), which left
it empty. The mechanism stays as an extension point.

The Dokploy panel is never exposed publicly: port 3000 is closed in UFW and only
traffic arriving on `tailscale0` is accepted in the `DOCKER-USER` chain. The box's
only public inbound ports are 22, 80 and 443.

### Dokploy version

The bootstrap installs the **latest** Dokploy release rather than a pinned one, and
reports back the version it actually got by reading the running service's image tag.
Dokploy's own auto-updater stays disabled (`SKIP_AUTO_UPDATE=true`) — installing the
newest at bootstrap and letting the panel upgrade itself unattended forever after are
separate decisions, and only the first one is taken. The trade-off: a rebuild months
from now yields a different Dokploy than today, so the bootstrap is not
byte-for-byte reproducible over time.

---

## Re-provisioning the server

A clean wipe + rebuild of the Strato VPS (`87.106.73.236`), which hosts every
application under `*.denniskasper.dev`. The public IP **is preserved** across a
Strato reinstall, so DNS doesn't change. Expect the apps to be down for the
duration; `denniskasper.com` is unaffected — it is served by Cloudflare Workers,
not by this box.

### 0. Gather first
- **Tailscale auth key** — the one hard blocker (the bootstrap aborts at
  `tailscale up` without it). Generate at <https://login.tailscale.com/admin/settings/keys>.
  Leave **Ephemeral off** and disable key expiry on the node: this box is not
  disposable, and a node that drops during an outage takes the Dokploy panel with it.
  Starts `tskey-auth-`.
- **Gmail app password** for `dennis.m.kasper@gmail.com` — see the appendix.
  (Non-blocking: a wrong/blank one only makes alert mail WARN.)
- **SSH public key** for `dennis` (e.g. `~/.ssh/id_ed25519.pub`).

### 1. Strato — reinstall to Ubuntu 24.04 LTS
Strato panel → **Mein Server → Neuinstallation** → **Ubuntu 24.04 LTS** → set a root
password (or paste an SSH key) → confirm. Public IP is preserved.

### 2. Bootstrap (as root)
```bash
ssh root@87.106.73.236
curl -fsSL https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/init-server.sh -o init-server.sh && \
  bash init-server.sh
```
The box has no keys, no git and no `gh` — it fetches the script over HTTPS from the
public repo, so any change to `init-server.sh` must be **pushed to `main`** before a
rebuild. Consider pinning the URL to a commit SHA rather than `main`, so the rebuild
runs the script you reviewed.

Answer the prompts:

| Prompt | Answer |
|---|---|
| Username | `dennis` |
| SSH public key | your `~/.ssh/id_ed25519.pub` |
| Tailscale hostname | `strato-box` |
| Tailscale auth key | your persistent, non-expiring key |
| Alert / SMTP email | `dennis.m.kasper@gmail.com` |
| SMTP app password | your Gmail app password (appendix) |

The hostname is validated as a DNS label and the script exits early if it isn't one,
rather than letting Tailscale silently sanitise it behind your back.

Before the final prompt, in a **second terminal** confirm `ssh dennis@87.106.73.236`
works (and `sudo -v`). Only then answer **`yes`** to "Can you SSH in as dennis?" —
that disables root login.

> `init-server.sh` refuses to run where Docker volumes already exist unless
> `--force` is passed. Harmless on a blank machine — but it does mean a failed run
> can't simply be re-run.

### 3. Dokploy admin
Open **`http://strato-box.tailf9113a.ts.net:3000`** over Tailscale — **use this
MagicDNS URL, not the IP.** Dokploy pins its origin to the host you first register
at; registering via the IP breaks Tailscale-name access afterward. Create the admin
account and enable **2FA**.

### 4. DNS and origin TLS
- `*.denniskasper.dev` → `87.106.73.236`, **proxied (🟠)**.
- A specific **grey (DNS-only)** `turn` record overrides the wildcard: coturn is
  UDP/3478 and cannot pass through the proxy. A more specific record always wins.
- At the origin, install a **Cloudflare Origin CA certificate** in Traefik. It is
  free, valid 15 years, and trusted only by Cloudflare — which is all that is needed
  behind the proxy. This replaces the Let's Encrypt DNS-01 resolver and the
  `CF_DNS_API_TOKEN` an earlier version of this runbook called for, and removes
  certificate renewal entirely.
- Zone SSL/TLS mode: **Full (strict)**.

### 5. Deploys: CI over the tailnet
There is **no public door** into the deployment system — no Cloudflare tunnel, no
`cloudflared`, no `deploy.*` hostname. GitHub Actions joins the tailnet as an
ephemeral node and POSTs to the Dokploy webhook from inside it.

One-time, in Tailscale:
- Create an **OAuth client** with the `auth_keys` scope, bound to a new ACL tag such
  as `tag:ci`.
- Add an ACL grant letting `tag:ci` reach `strato-box` on port **3000**, and nothing
  else.

Per application repo:
- Add `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` repository secrets.
- Add a deploy workflow that runs `tailscale/github-action`, then POSTs to that app's
  Dokploy webhook over the tailnet.

That is the accepted price of the choice: every new application costs a workflow and
two secrets, in exchange for the box having no public entry point beyond 22/80/443.

### 6. Deploy the applications
Create each app in the Dokploy UI and give it its `*.denniskasper.dev` hostname.

> ⚠️ **Check the container's real port.** The unprivileged nginx image serves on
> `8080`, not `80`; mapping a domain to the wrong port yields an instant
> **`502 Bad Gateway`** (Traefik routes to a dead port).

### 7. Cleanup
- Delete **orphaned** Dokploy GitHub Apps in GitHub — the ones the rebuild replaced.
  **Never delete the app a live server is using**; it breaks that server's auto-deploy.
- Remove any stale offline node from the Tailscale admin console.

---

## Monitoring

**Liveness is monitored externally, off this machine.** A cron on the box cannot
report that the box is down: if the machine dies, the cron and the mail relay die
with it. An external HTTP monitor (UptimeRobot free tier or equivalent, 5-minute
interval) pointed at the application whose downtime actually costs something is the
only thing that can detect a dead box.

What stays **on** the box is the disk-full alert — a condition the machine can
observe about itself while it is alive — delivered through the msmtp relay that
`init-server.sh` configures.

---

## Appendix — create a Gmail app password
App passwords are shown **once** and can't be retrieved later — generate a new one
if you don't have it saved.

1. Requires **2-Step Verification** enabled on the account.
2. Go to <https://myaccount.google.com/apppasswords> (or Google Account → **Security**
   → **2-Step Verification** → **App passwords**).
3. Name it (e.g. `msmtp strato-box`) → **Create** → copy the **16-character** code
   (drop the spaces).
4. Use it as the SMTP password at bootstrap step 2. Host/port/user are baked in:
   `smtp.gmail.com:587`, user = the alert email.

---

## Enterprise-readiness — open notes (NOT decided, to revisit)

> Status: **undecided / parked.** Captured to pick up later *if* this setup ever needs to
> serve real customers / carry an SLA. Today: single VPS + Dokploy + Traefik, Cloudflare in
> front, admin Tailscale-only, CI on the tailnet. This is a solid Tier-0 setup; the notes
> below are the path up.

### The ingress hardening that matters is at the origin
Customer traffic goes Cloudflare → Traefik `:443`. With the wildcard proxied and an
Origin CA certificate installed, the remaining gap is that the origin IP is known and
`:80/:443` are open, so an attacker can bypass Cloudflare/WAF by hitting the IP
directly. Options: lock the origin firewall to **Cloudflare IP ranges** + **Authenticated
Origin Pulls** (mTLS CF→origin), or move customer traffic onto a Cloudflare Tunnel too
(origin outbound-only). Note the deploy path is *not* part of this exposure any more —
CI reaches Dokploy over the tailnet, and nothing about deploys is publicly reachable.

### Bigger gaps to close before "enterprise" (priority order)
1. **Backups / DR — currently none.** Automated off-box DB backups (S3/R2) + a *tested* restore
   runbook; move stateful apps to **managed Postgres** (PITR, failover).
2. **HA / single-VPS SPOF.** One box runs Traefik + apps + Dokploy + Postgres; its death = full
   outage. Multi-node Swarm (Dokploy supports worker nodes) or a managed platform behind a load
   balancer; ≥2 app nodes across AZs.
3. **Observability / on-call.** Today: an external HTTP monitor plus the on-box disk alert. Add
   multi-region probes + escalation (PagerDuty/Opsgenie), metrics/logs, alerts on
   error-rate/latency/cert expiry/disk. (Note the known "Dokploy healthcheck green but UI 500"
   failure mode — needs end-to-end probing, not just a port check.)
4. **Secrets management.** Pasted into the Dokploy UI today (not auditable; lose Dokploy =
   regenerate everything). Move to Vault / Doppler / Infisical / a cloud secrets manager with
   rotation + audit.
5. **Release safety.** A true staging mirror, migration gates, blue-green/canary, easy rollback.
   There is one box; there is no prod-parity staging.
6. **Compliance** (only if customers demand SOC2 / ISO / GDPR): audit logs, access control,
   change management, incident-response plan, DPA, data residency.
7. **Scale.** Fixed CPU/RAM on one VPS; enterprise load needs horizontal scale + autoscale + LB.
8. **Reproducible bootstrap.** Dokploy is installed unpinned, so two rebuilds months apart give
   two different panels. Re-pinning is a one-line change if that ever matters.

### What's already good (keep)
Reproducible `init-server.sh` (IaC foundation) with every host fact as an input; Dokploy's
auto-updater disabled; **admin plane and deploy path both off the public internet**;
Cloudflare front (DDoS / WAF / TLS) with an Origin CA cert that never needs renewing;
hardened host (UFW, fail2ban, key-only SSH, no root, unattended security upgrades);
liveness monitored from outside the box.

### Maturity ladder
- **Tier 0 (today):** portfolio + low-stakes apps (few users, no SLA, no sensitive data).
- **Tier 1 (first paying customers):** off-box backups + tested restore, external monitoring +
  on-call, managed Postgres, a real staging env.
- **Tier 2 (enterprise SLAs):** multi-node HA + LB across AZs, managed DB w/ failover + PITR,
  secrets manager, full observability, Terraform + GitOps, DR plan with RTO/RPO targets, origin
  locked to Cloudflare, compliance program.

### To answer when we pick this up
- Stateful app with customer data, or stateless-at-scale? (decides whether backups/DB or HA/CDN dominate)
- Target SLA / acceptable downtime?
- Data sensitivity / compliance (PII, payments, SOC2)?
- Expected load / growth curve?
