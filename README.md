# server-bootstrap

Provisions a hardened single-node Dokploy server on a fresh Ubuntu LTS VPS:
OS hardening, swap, Docker Swarm, Tailscale, UFW + ufw-docker, fail2ban, an SMTP
relay for alerts, and Dokploy itself.

It holds no facts about any particular machine. Every host-specific value is an
input — the username, the SSH public key, the Tailscale hostname, the auth key,
the alert mailbox. Substitute your own wherever this README shows `<angle
brackets>`.

## Contents

- [`init-server.sh`](init-server.sh) — the whole bootstrap, one file.

---

## Quickstart

Run as **root** on a fresh Ubuntu LTS VPS:

```bash
curl -fsSL https://raw.githubusercontent.com/denniskasper/server-bootstrap/main/init-server.sh -o init-server.sh && \
  bash init-server.sh
```

A blank box has no keys, no git and no `gh`, so it fetches over plain HTTPS from
the public repo. Anything you change here must be **pushed to `main`** before it
can be used. Consider pinning the URL to a commit SHA rather than `main`, so a
rebuild runs the script you reviewed rather than whatever `main` holds that day.

### Inputs

Each value is taken from the environment if set, and prompted for otherwise:

| Variable | Prompt | Notes |
|---|---|---|
| `NEW_USER` | Username to create | validated as a Linux username |
| `SSH_PUBKEY` | SSH public key | your **`.pub`**, from the machine you SSH *from* |
| `TS_HOSTNAME` | Tailscale hostname | validated as a DNS label |
| `TS_AUTHKEY` | Tailscale auth key | hidden input |
| `ALERT_EMAIL` | Alert / SMTP sender email | receives disk alerts |
| `SMTP_PASSWORD` | SMTP app password | hidden input; see the appendix |
| `SSH_TEST` | the pre-lockdown confirmation | see [SSH lockdown](#ssh-lockdown) |
| `SWAP_SIZE` | — | env only, default `4G`; `0` disables |

Supplying all of them lets the script run unattended, which is what makes a
rehearsal cheap:

```bash
NEW_USER=deploy SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
TS_HOSTNAME=web-01 TS_AUTHKEY=tskey-auth-… \
ALERT_EMAIL=alerts@example.com SMTP_PASSWORD=… SSH_TEST=yes \
  bash init-server.sh
```

**Rehearse before you rely on it.** Spin up the cheapest VPS your provider
offers, run the script end to end, confirm the panel comes up over the tailnet,
destroy it. It costs pennies and it is the difference between finding a mistake
on a disposable box and finding it on one with your data on it.

> **Not idempotent.** The script refuses to run where Docker volumes already
> exist unless `--force` is passed. Harmless on a blank machine — but it does
> mean a failed run can't simply be re-run.

---

## Provisioning a server

### 0. Gather first
- **Tailscale auth key** — the one hard blocker; the bootstrap aborts at
  `tailscale up` without it. Generate at
  <https://login.tailscale.com/admin/settings/keys>. Leave **Ephemeral off** and
  disable key expiry on the node: a node that drops during an outage takes the
  Dokploy panel with it. Starts `tskey-auth-`.
- **SMTP app password** for the alert mailbox — see the appendix. Non-blocking:
  a wrong one only makes the test mail WARN.
- **SSH public key**, e.g. `~/.ssh/id_ed25519.pub`.

### 1. Install a clean OS
Your provider's control panel → reinstall → **Ubuntu 24.04 LTS** → set a root
password or paste an SSH key. Check whether the public IP survives the
reinstall; most providers preserve it, which saves a DNS change.

### 2. Bootstrap
`ssh root@<origin-ip>`, then run the [quickstart](#quickstart) command and
answer the prompts. Values are validated as they are read, so a mistyped
hostname or a pasted *private* key stops the run immediately rather than
surfacing as a lockout twenty minutes later.

### 3. Dokploy admin
Open **`http://<hostname>.<tailnet>.ts.net:3000`** over Tailscale — **use the
MagicDNS name, not the IP.** Dokploy pins its origin to the host you first
register at; registering via the IP breaks name-based access afterward. Create
the admin account and enable **2FA**.

### 4. DNS and origin TLS
A wildcard keeps per-app DNS work at zero:

- `*.<your-domain>` → `<origin-ip>`, **proxied (🟠)**.
- Anything that can't survive the proxy needs a more specific **grey (DNS-only)**
  record to override the wildcard — a TURN server on UDP/3478, for instance. A
  more specific record always wins.
- At the origin, install a **Cloudflare Origin CA certificate** in Traefik. Free,
  valid 15 years, trusted only by Cloudflare — which is all that is needed behind
  the proxy. It removes certificate renewal entirely, and with it the Let's
  Encrypt DNS-01 resolver and its scoped API token.
- Zone SSL/TLS mode: **Full (strict)**.

### 5. Deploys: CI over the tailnet
There is **no public door** into the deployment system — no tunnel, no
`cloudflared`, no `deploy.*` hostname. CI joins the tailnet as an ephemeral node
and POSTs to the Dokploy webhook from inside it.

One-time, in Tailscale:
- Create an **OAuth client** with the `auth_keys` scope, bound to a tag such as
  `tag:ci`.
- Add an ACL grant letting `tag:ci` reach the node on port **3000**, and nothing
  else.

Per application repo:
- Add `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` repository secrets.
- Add a deploy workflow that runs `tailscale/github-action`, then POSTs to that
  app's Dokploy webhook over the tailnet.

That is the accepted price: every new application costs a workflow and two
secrets, in exchange for the box having no public entry point beyond 22/80/443.

### 6. Deploy the applications
Create each app in the Dokploy UI and give it its hostname under the wildcard.

> ⚠️ **Check the container's real port.** The unprivileged nginx image serves on
> `8080`, not `80`; mapping a domain to the wrong port yields an instant
> **`502 Bad Gateway`** — Traefik routing to a dead port.

### 7. Cleanup
- Delete **orphaned** Dokploy GitHub Apps that a rebuild replaced. **Never delete
  the app a live server is using**; it breaks that server's auto-deploy.
- Remove any stale offline node from the Tailscale admin console.

---

## What the script sets up

### SSH lockdown
The run **pauses before disabling root login** and will not continue without a
second terminal: it prints the exact `ssh` command and waits for a literal
`yes`. Anything else aborts with root login still enabled. Only after
confirmation does it write the hardening config — no root login, no password
auth, keys only — validate it with `sshd -t`, and reload.

`SSH_TEST=yes` in the environment skips the pause, which is what allows an
unattended rehearsal to finish. Don't set it on a box you can't afford to be
locked out of; the point of the pause is that a human proved the new key works
while root was still available.

### Network exposure
Public: **22, 80, 443**. That's all.

The Dokploy panel on :3000 is never exposed. UFW alone isn't enough — Docker's
DNAT runs in `PREROUTING`, before UFW's `INPUT` chain ever sees the packet — so
the script installs [`ufw-docker`](https://github.com/chaifeng/ufw-docker) and
adds a rule to `/etc/ufw/after.rules` accepting traffic on the `tailscale0`
interface inside the `DOCKER-USER` chain. Writing it to `after.rules` rather
than calling `iptables` is what makes it survive a reboot.

Once the tailnet is up and you've confirmed Tailscale SSH works, closing **22**
as well is worth considering: it drops the public surface to 80/443 and makes
SSH brute-forcing a non-category. Only do it with console access available.

### Disk
Three defences, because a full disk is the most common way a small box dies:
- journald capped at **500 MB**.
- Docker daemon log rotation (10 MB × 3), written **before** Docker first starts.
- A daily prune of dangling images, stopped containers, **and the BuildKit
  cache** — the last is what actually grows without bound on a box that builds
  its own images, and the first two commands don't touch it. Volumes are
  deliberately never pruned; that's where the data lives.

Plus a cron that emails `ALERT_EMAIL` when `/` passes 80%.

### Swap
VPS images frequently ship with none. Docker builds spike well past steady-state
memory, and with no swap the OOM killer takes the build — or something that
matters more — with no warning worth reading. The script creates a **4 GB**
swapfile with `vm.swappiness=10`, so it acts as an overflow valve rather than a
paging strategy. Set `SWAP_SIZE=0` to skip, or e.g. `SWAP_SIZE=2G` to resize.
Existing swap is left alone.

### Dokploy version
Installs the **latest** release rather than a pinned one, then reports the
version it actually got by reading the running service's image tag. Dokploy's
own auto-updater stays disabled (`SKIP_AUTO_UPDATE=true`): installing the newest
at bootstrap and letting the panel upgrade itself unattended forever after are
separate decisions, and only the first is taken here. The trade-off is that two
rebuilds months apart give two different panels.

### Site overlay (optional)
Anything host-specific in *behaviour* — app deploy steps, owner policy — can live
in an overlay that runs near the end, after the base system exists.

- Point `SITE_INIT` at a **URL or a local path**. It defaults to a `site-init.sh`
  beside `init-server.sh`; if nothing is found the step is skipped, so the script
  runs standalone.
- The overlay receives `ALERT_EMAIL`, `PUBLIC_IP`, `TAILSCALE_IP`, `TS_HOSTNAME`
  and `NEW_USER` in its environment.

This repo ships no overlay. The mechanism costs nothing and stays.

### What it pulls at runtime
Four unpinned fetches: `ufw-docker` from `master`, Docker's install script (only
as a fallback), and two Dokploy scripts. Worth knowing if you care about
reproducibility — it's the same reason to pin `init-server.sh` itself to a SHA.

---

## Monitoring

**Liveness has to be watched from somewhere else.** A cron on the box cannot
report that the box is down: if the machine dies, the cron and the mail relay die
with it. An external HTTP monitor (UptimeRobot's free tier or equivalent,
5-minute interval) pointed at whichever app's downtime actually costs something
is the only thing that detects a dead box.

What belongs **on** the box is the disk alert — a condition the machine can
observe about itself while it's alive — delivered through the msmtp relay the
bootstrap configures.

---

## Appendix — creating a Gmail app password
The SMTP relay is preconfigured for `smtp.gmail.com:587`. App passwords are shown
**once** and can't be retrieved later.

1. Requires **2-Step Verification** on the account.
2. Go to <https://myaccount.google.com/apppasswords> (or Google Account →
   **Security** → **2-Step Verification** → **App passwords**).
3. Name it (e.g. `msmtp <hostname>`) → **Create** → copy the **16-character**
   code, dropping the spaces.
4. Use it as `SMTP_PASSWORD`. Host, port and user are derived: the user is the
   alert email.

For a different provider, change `SMTP_HOST` / `SMTP_PORT` near the top of the
script.

---

## Known gaps

Deliberately out of scope, listed so they aren't mistaken for oversights:

- **No backups.** Databases, `/etc/dokploy` (every app definition and
  environment variable) and the secrets held in the Dokploy UI all live only on
  this box. Set up off-box backups separately — and restore one at least once.
- **Single node.** Traefik, apps, Dokploy and any database share one machine;
  its death is a full outage.
- **Origin reachable directly.** With a proxied wildcard, the origin IP is still
  public and `:80/:443` are open, so Cloudflare's WAF can be bypassed by
  connecting to the IP. Restricting those ports to Cloudflare's published ranges
  closes it.
- **Secrets live in the Dokploy UI.** Not auditable, and losing Dokploy means
  regenerating everything.
- **No staging.** One box, no prod-parity mirror.

## Licence

MIT — see [LICENSE](LICENSE).
