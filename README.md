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

`deploy-tunnel-init.sh` stands up the locally-managed cloudflared tunnel that
exposes **only** the Dokploy deploy webhook publicly, keeping the admin panel
Tailscale-only. It's idempotent and parameterized by `ROLE`. See step 4 below.

---

## Re-provisioning the production server (denniskasper.com)

A clean wipe + rebuild of the Strato prod VPS. `denniskasper.com` is a **stateless
Astro static site** — a wipe loses nothing; you redeploy from Git. Expect ~30–60 min
of site downtime. The public IP **`87.106.73.236`** is preserved across a Strato
reinstall, so the Cloudflare apex A record doesn't change.

> **int** (the Hetzner box, domain `denniskasper.dev`) is the *same* procedure with
> `role=int`, hostname `dokploy-int`, and `deploy.denniskasper.dev`.

### 0. Gather first
- **Tailscale ephemeral auth key** — the one hard blocker (the bootstrap aborts at
  `tailscale up` without it). Generate at <https://login.tailscale.com/admin/settings/keys>,
  toggle **Ephemeral**. Starts `tskey-auth-`.
- **Gmail app password** for `dennis.m.kasper@gmail.com` — see the appendix.
  (Non-blocking: a wrong/blank one only makes alert mail WARN.)
- **SSH public key** for `dennis` (e.g. `~/.ssh/id_ed25519.pub`).

### 1. Strato — reinstall to Ubuntu 26.04
Strato panel → **Mein Server → Neuinstallation** → **Ubuntu 26.04** → set a root
password (or paste an SSH key) → confirm. Public IP is preserved. The site is down
from here until step 6.

### 2. Bootstrap (as root)
```bash
ssh root@87.106.73.236
curl -fsSL https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/init-server.sh -o init-server.sh && \
  SITE_INIT=https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/site-init.sh bash init-server.sh
```
Answer the prompts:

| Prompt | Answer |
|---|---|
| Username | `dennis` |
| SSH public key | your `~/.ssh/id_ed25519.pub` |
| Server role | `prod` |
| Tailscale auth key | your ephemeral key |
| Alert / SMTP email | `dennis.m.kasper@gmail.com` |
| SMTP app password | your Gmail app password (appendix) |
| URLs to monitor | `https://denniskasper.com` |
| Cloudflare tunnel token | **leave BLANK** — the tunnel is set up in step 4 |

Before the final prompt, in a **second terminal** confirm `ssh dennis@87.106.73.236`
works (and `sudo -v`). Only then answer **`yes`** to "Can you SSH in as dennis?" —
that disables root login.

### 3. Dokploy admin
Open **`http://dokploy-prod.tailf9113a.ts.net:3000`** over Tailscale — **use this
MagicDNS URL, not the IP.** Dokploy pins its origin to the host you first register
at; registering via the IP breaks Tailscale-name access afterward. Create the admin
account and enable **2FA**.

### 4. Deploy webhook tunnel
In a root shell (`sudo -i`, so `HOME=/root`):
```bash
curl -fsSL https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/deploy-tunnel-init.sh -o deploy-tunnel-init.sh && bash deploy-tunnel-init.sh
```
It pauses once at `cloudflared tunnel login` — open the printed URL, authorize the
**denniskasper.com** zone — then it creates the `dokploy-prod` tunnel, the proxied
`deploy.denniskasper.com` DNS record, the path-scoped config + service, and
self-verifies (`/`→404, `/api/deploy/github`→401). For int: `ROLE=int bash deploy-tunnel-init.sh`.

### 5. GitHub App + webhook
Dokploy → **Settings → Git → Create GitHub App** (completes on GitHub). Then in
**GitHub → Developer settings → GitHub Apps → [the app] → General**, set
**Webhook URL = `https://deploy.denniskasper.com/api/deploy/github`** — override the
prefilled Tailscale URL (that mismatch was the original breakage). **Don't** clear
the webhook secret; **don't** add a repo-level webhook. Then **Install** the app on
the `denniskasper.com` repo.

### 6. Deploy the site
Create the app from `git@github.com:denniskasper/denniskasper.com.git`, branch
**`main`**. Add domain **`denniskasper.com`** → **HTTPS / Let's Encrypt** →
**Port `8080`**.

> ⚠️ **Port is `8080`, not `80`.** The unprivileged nginx image serves on `8080`;
> mapping the domain to `80` yields an instant **`502 Bad Gateway`** (Traefik routes
> to a dead port).

**TLS + Cloudflare:** keep the apex `denniskasper.com` A record **grey (DNS-only)**
until the LE cert issues via HTTP-01 and the site loads; **then** flip it to
**Proxied (orange)** and set the zone's **SSL/TLS mode to Full (strict)** (the
origin's LE cert satisfies strict). Issuing HTTP-01 while orange is unreliable.

### 7. Verify auto-deploy
```bash
git -C path/to/denniskasper.com commit --allow-empty -m "verify deploy"
git -C path/to/denniskasper.com push origin main
```
GitHub → the app → **Advanced → Recent Deliveries** should show **200**; Dokploy
auto-deploys.

### 8. Cleanup
- Delete the **orphaned** Dokploy GitHub Apps in GitHub (the old prod app the rebuild
  replaced, plus any pre-existing orphan). **Never delete the app a live server is
  using** — it breaks that server's auto-deploy.
- Remove any stale offline node from the Tailscale admin console.
- **Cloudflare DNS** — final state is three **Proxied (🟠)** records and nothing else:
  `denniskasper.com` (A → `87.106.73.236`), `deploy` (the tunnel CNAME), and `www`
  (CNAME → `denniskasper.com`). Delete the `*` wildcard. SSL/TLS mode stays **Full (strict)**.
- **`www` → apex redirect.** A proxied `www` with no rule would 502 (Traefik has no `www`
  route), so redirect it at Cloudflare's edge: **Rules → Redirect Rules → Create** (the
  "Redirect from WWW to root" template), then:
  - **Match: Custom filter expression** — `http.host eq "www.denniskasper.com"`.
    **Do not** use "All incoming requests", or the apex matches too and redirects to
    itself → infinite loop on the main site.
  - **Then:** Type **Dynamic** · `wildcard_replace(http.request.full_uri, "https://www.*", "https://${1}")` · **301** · **Preserve query string OFF** (`full_uri` already
    carries the query — enabling it doubles `?…`).

---

## Appendix — create a Gmail app password
App passwords are shown **once** and can't be retrieved later — generate a new one
if you don't have it saved.

1. Requires **2-Step Verification** enabled on the account.
2. Go to <https://myaccount.google.com/apppasswords> (or Google Account → **Security**
   → **2-Step Verification** → **App passwords**).
3. Name it (e.g. `msmtp prod`) → **Create** → copy the **16-character** code (drop the
   spaces).
4. Use it as the SMTP password at bootstrap step 2. Host/port/user are baked in:
   `smtp.gmail.com:587`, user = the alert email.

---

## Enterprise-readiness — open notes (NOT decided, to revisit)

> Status: **undecided / parked.** Captured to pick up later *if* this setup ever needs to
> serve real customers / carry an SLA. Today: single VPS + Dokploy + Traefik, Cloudflare in
> front, admin Tailscale-only. This is a solid Tier-0 setup; the notes below are the path up.

### The deploy tunnel is *not* the weak link
The cloudflared tunnel carries **only the CI deploy webhook** (`deploy.<domain>/api/deploy/github`
→ `localhost:3000`). **Customer traffic never uses it** — visitors hit Cloudflare → Traefik
`:443` directly. If the connector dies, deploys stop but the site stays up. For HA, run 2+
`cloudflared` replicas of the same named tunnel (Cloudflare load-balances them).

The real ingress hardening is the **origin**, not the tunnel: the origin IP is known and
`:80/:443` are open, so an attacker can bypass Cloudflare/WAF by hitting the IP directly.
Options: lock the origin firewall to **Cloudflare IP ranges** + **Authenticated Origin Pulls**
(mTLS CF→origin), or move customer traffic onto a Cloudflare Tunnel too (origin outbound-only).

### Bigger gaps to close before "enterprise" (priority order)
1. **Backups / DR — currently none.** Automated off-box DB backups (S3/R2) + a *tested* restore
   runbook; move stateful apps to **managed Postgres** (PITR, failover). (The prod homepage is
   static/stateless → low risk; the only stateful piece today is OL's Postgres on int.)
2. **HA / single-VPS SPOF.** One box runs Traefik + apps + Dokploy + Postgres; its death = full
   outage. Multi-node Swarm (Dokploy supports worker nodes) or a managed platform behind a load
   balancer; ≥2 app nodes across AZs.
3. **Observability / on-call.** Today: hourly uptime cron + disk alert. Add external multi-region
   probes + escalation (PagerDuty/Opsgenie), metrics/logs, alerts on error-rate/latency/cert
   expiry/disk. (Note the known "Dokploy healthcheck green but UI 500" failure mode — needs
   end-to-end probing, not just a port check.)
4. **Secrets management.** Pasted into the Dokploy UI today (not auditable; lose Dokploy =
   regenerate everything). Move to Vault / Doppler / Infisical / a cloud secrets manager with
   rotation + audit.
5. **Release safety.** A true staging mirror, migration gates, blue-green/canary, easy rollback.
   (int / `denniskasper.dev` is a playground, not prod-parity.)
6. **Compliance** (only if customers demand SOC2 / ISO / GDPR): audit logs, access control,
   change management, incident-response plan, DPA, data residency.
7. **Scale.** Fixed CPU/RAM on one VPS; enterprise load needs horizontal scale + autoscale + LB.

### What's already good (keep)
Reproducible `init-server.sh` (IaC foundation); pinned Dokploy + auto-update disabled;
**admin plane off the public internet (Tailscale-only)**; Cloudflare front (DDoS / WAF / TLS);
hardened host (UFW, fail2ban, key-only SSH, no root, unattended security upgrades); clean
int/prod split.

### Maturity ladder
- **Tier 0 (today):** portfolio + low-stakes prod (few users, no SLA, no sensitive data).
- **Tier 1 (first paying customers):** off-box backups + tested restore, external monitoring +
  on-call, managed Postgres, a real staging env, a 2nd tunnel connector.
- **Tier 2 (enterprise SLAs):** multi-node HA + LB across AZs, managed DB w/ failover + PITR,
  secrets manager, full observability, Terraform + GitOps, DR plan with RTO/RPO targets, origin
  locked to Cloudflare, compliance program.

### To answer when we pick this up
- Stateful app with customer data, or stateless-at-scale? (decides whether backups/DB or HA/CDN dominate)
- Target SLA / acceptable downtime?
- Data sensitivity / compliance (PII, payments, SOC2)?
- Expected load / growth curve?
