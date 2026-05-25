#!/usr/bin/env bash
# Generic Dokploy server bootstrap — hardens a fresh Ubuntu LTS VPS and installs
# Docker Swarm + Dokploy. Holds no host- or owner-specific facts; anything tied
# to a particular server (which apps to monitor, deploy reminders, etc.) lives
# in an optional site overlay — see the "Site-specific overlay" section.
# Usage: bash init-server.sh [--force]   (run as root on a fresh Ubuntu LTS VPS)
# Quickstart (fetch + run from main, with this repo's overlay):
#   curl -fsSL https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/init-server.sh -o init-server.sh && \
#     SITE_INIT=https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/site-init.sh bash init-server.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOKPLOY_VERSION="v0.29.4"
SMTP_HOST="smtp.gmail.com"
SMTP_PORT="587"
UFW_DOCKER_URL="https://raw.githubusercontent.com/chaifeng/ufw-docker/master/ufw-docker"

# ─── Safety check ────────────────────────────────────────────────────────────

FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

if docker info &>/dev/null 2>&1 && docker volume ls -q | grep -q .; then
  if [[ "$FORCE" != true ]]; then
    echo "ERROR: Existing Docker volumes detected on this server." >&2
    echo "Re-running init-server.sh would destroy data." >&2
    echo "If you are certain, run: bash init-server.sh --force" >&2
    exit 1
  fi
  echo "WARNING: --force passed. Proceeding on server with existing data." >&2
fi

# ─── Interactive prompts ──────────────────────────────────────────────────────

echo ""
echo "=== init-server.sh — Dokploy server bootstrap ==="
echo ""

read -rp "Username to create (e.g. dennis): " NEW_USER

# SSH_PUBKEY is the operator's *public* key, which lives on their LOCAL machine
# (the one they SSH from) — not on this server. Retrieve it locally with:
#   cat ~/.ssh/id_ed25519.pub   (or ~/.ssh/id_rsa.pub)
# No key yet? Create one locally with `ssh-keygen -t ed25519`, then cat the .pub.
echo ""
echo "Paste the SSH PUBLIC key for ${NEW_USER} — from your LOCAL machine, not this server."
echo "  Print it locally:  cat ~/.ssh/id_ed25519.pub   (or ~/.ssh/id_rsa.pub)"
echo "  No key yet?        ssh-keygen -t ed25519   then cat the .pub file"
echo "  Use the .pub (starts 'ssh-ed25519'/'ssh-rsa') — never the private key."
read -rp "SSH public key: " SSH_PUBKEY

# Roles: 'int' = integration (a non-prod server; sends no mail) · 'prod' =
# production (mail relay + uptime/disk alerts). 'dev' now means local development
# only — no server — so it is intentionally not a valid role here.
read -rp "Server role [int|prod]: " SERVER_ROLE

if [[ "$SERVER_ROLE" != "int" && "$SERVER_ROLE" != "prod" ]]; then
  echo "ERROR: role must be 'int' or 'prod'" >&2
  exit 1
fi

# TS_AUTHKEY is generated in the Tailscale admin console (it is NOT a password).
# Generate an *ephemeral* key so the node auto-removes when it goes offline:
#   https://login.tailscale.com/admin/settings/keys  →  "Generate auth key"
echo ""
echo "Tailscale auth key — generate one in the admin console (not a password):"
echo "  https://login.tailscale.com/admin/settings/keys  ->  'Generate auth key'"
echo "  Enable 'Ephemeral' so this node auto-removes when offline. Starts 'tskey-auth-'."
read -rsp "Tailscale auth key (input hidden): " TS_AUTHKEY
echo ""

# Mail relay credentials — prod only. Int sends no mail, so none are collected.
ALERT_EMAIL=""
SMTP_PASSWORD=""
if [[ "$SERVER_ROLE" == "prod" ]]; then
  read -rp  "Alert / SMTP sender email (receives disk + uptime alerts): " ALERT_EMAIL
  read -rsp "SMTP app password for ${ALERT_EMAIL}: " SMTP_PASSWORD
  echo ""
fi

# ─── Detect public IP ────────────────────────────────────────────────────────

# Prefer IPv4 — Swarm advertise-addr and the SSH-test hint need a v4 address that
# clients can actually reach; fall back to whatever curl returns on a v6-only host.
PUBLIC_IP=$(curl -4 -fsS --retry 3 ifconfig.me 2>/dev/null || curl -fsS --retry 3 ifconfig.me)
echo "Detected public IP: ${PUBLIC_IP}"

# ─── System updates ──────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get full-upgrade -yq

apt-get install -yq \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban \
  systemd-timesyncd

# Mail relay packages only on prod — int sends no email.
if [[ "$SERVER_ROLE" == "prod" ]]; then
  apt-get install -yq msmtp msmtp-mta mailutils
fi

# Strip orphaned packages and cached archives for a clean baseline.
apt-get autoremove -yq
apt-get autoclean -q

# ─── journald size cap ───────────────────────────────────────────────────────

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf <<'EOF'
[Journal]
SystemMaxUse=500M
EOF
systemctl restart systemd-journald

# ─── unattended-upgrades ─────────────────────────────────────────────────────

apt-get install -yq unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now unattended-upgrades

# ─── Docker (official apt repo) ──────────────────────────────────────────────

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

# ─── Docker daemon log rotation — written BEFORE Docker starts ───────────────

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

apt-get update -q
if ! apt-get install -yq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
  echo "WARN: Docker apt repo install failed (codename $(lsb_release -cs) may not yet be supported)."
  echo "      Falling back to official Docker convenience script..."
  rm -f /etc/apt/sources.list.d/docker.list
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

systemctl enable --now docker

# ─── Docker Swarm ─────────────────────────────────────────────────────────────

docker swarm init --advertise-addr "${PUBLIC_IP}"

# ─── Tailscale ───────────────────────────────────────────────────────────────

curl -fsSL https://tailscale.com/install.sh | sh
# Deterministic node name → predictable MagicDNS URL (dokploy-int / dokploy-prod)
# instead of the cloud's default hostname; the ephemeral node re-registers cleanly.
tailscale up --authkey="${TS_AUTHKEY}" --ssh --hostname="dokploy-${SERVER_ROLE}"
TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP: ${TAILSCALE_IP}"

# ─── Dokploy (pinned version) ────────────────────────────────────────────────

echo "Installing Dokploy ${DOKPLOY_VERSION}..."

# Download and inspect Dokploy install script before running
DOKPLOY_INSTALL_SCRIPT=$(mktemp)
curl -fsSL "https://dokploy.com/install.sh" -o "${DOKPLOY_INSTALL_SCRIPT}"
# Pin the version via environment variable that Dokploy's install.sh respects
DOKPLOY_VERSION="${DOKPLOY_VERSION}" bash "${DOKPLOY_INSTALL_SCRIPT}"
rm -f "${DOKPLOY_INSTALL_SCRIPT}"

# Apply Docker Secrets migration (removes legacy hardcoded postgres password)
echo "Applying Dokploy Docker Secrets fix..."
DOKPLOY_SEC_SCRIPT=$(mktemp)
curl -fsSL "https://dokploy.com/security/0.26.6.sh" -o "${DOKPLOY_SEC_SCRIPT}"
bash "${DOKPLOY_SEC_SCRIPT}"
rm -f "${DOKPLOY_SEC_SCRIPT}"

# Disable Dokploy's built-in auto-updater so version stays pinned
docker service update \
  --env-add SKIP_AUTO_UPDATE=true \
  dokploy 2>/dev/null || true

# ─── UFW + ufw-docker ────────────────────────────────────────────────────────

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   comment "SSH"
ufw allow 80/tcp   comment "HTTP"
ufw allow 443/tcp  comment "HTTPS"
# Port 3000 (Dokploy) intentionally NOT opened to the public — reachable only
# via Tailscale (persistent DOCKER-USER rule added below, after ufw-docker install)

ufw --force enable
systemctl enable ufw

curl -fsSL "${UFW_DOCKER_URL}" -o /usr/local/bin/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install

# Allow Traefik to receive external HTTP/HTTPS traffic (required for Let's Encrypt HTTP-01 challenge)
ufw-docker allow dokploy-traefik 80
ufw-docker allow dokploy-traefik 443

# Allow the Dokploy admin UI (port 3000) to be reached over Tailscale only.
# ufw-docker blocks Swarm-published ports by default, and a plain `ufw allow`
# rule does NOT help because Docker's DNAT runs in PREROUTING before UFW's INPUT
# chain ever sees the packet. The reliable, reboot-persistent fix is to accept
# traffic arriving on the tailscale0 interface inside the DOCKER-USER (FORWARD)
# chain, written into after.rules so UFW replays it on every boot.
sed -i '/^-A DOCKER-USER -j ufw-user-forward$/a -A DOCKER-USER -i tailscale0 -j ACCEPT' /etc/ufw/after.rules

systemctl restart ufw

# ─── fail2ban ────────────────────────────────────────────────────────────────

cat > /etc/fail2ban/jail.d/sshd.conf <<'EOF'
[sshd]
enabled  = true
maxretry = 5
bantime  = 1h
findtime = 10m
EOF

systemctl enable --now fail2ban

# ─── msmtp (SMTP relay) ──────────────────────────────────────────────────────

# Prod only — int sends no email (no SMTP relay configured).
if [[ "$SERVER_ROLE" == "prod" ]]; then
  cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        smtp
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${ALERT_EMAIL}
user           ${ALERT_EMAIL}
password       ${SMTP_PASSWORD}

account default : smtp
EOF
  chmod 600 /etc/msmtprc

  # Route system mail through msmtp
  ln -sf /usr/bin/msmtp /usr/sbin/sendmail

  # Test mail delivery
  echo "Subject: init-server.sh — mail test from $(hostname)" \
    | msmtp "${ALERT_EMAIL}" || echo "WARN: test mail failed, check /var/log/msmtp.log"
fi

# ─── Disk hygiene cron ───────────────────────────────────────────────────────

cat > /etc/cron.daily/docker-prune <<'CRON'
#!/bin/sh
docker image prune -f
docker container prune -f
CRON
chmod +x /etc/cron.daily/docker-prune

# Disk-full email alert — prod only (int: no email; owner watches disk manually).
if [[ "$SERVER_ROLE" == "prod" ]]; then
  cat > /etc/cron.d/disk-alert <<CRON
*/5 * * * * root \
  USED=\$(df / --output=pcent | tail -1 | tr -d ' %'); \
  [ "\$USED" -gt 80 ] && echo "Disk usage on \$(hostname) is \${USED}%%" \
    | mail -s "ALERT: disk > 80%% on \$(hostname)" ${ALERT_EMAIL}
CRON
fi

# ─── Site-specific overlay (optional) ────────────────────────────────────────
# Everything tied to a *particular* server — which URLs to monitor, app deploy
# steps, owner-specific policy — is kept OUT of this generic bootstrap. Point at
# an overlay with SITE_INIT (a URL or a local path); it defaults to a site-init.sh
# next to this script — present on a repo clone, absent on a single-file curl.
# The overlay runs here, after the base system is in place, receiving
# SERVER_ROLE/ALERT_EMAIL/PUBLIC_IP/TAILSCALE_IP/NEW_USER. See site-init.example.sh.

SITE_INIT="${SITE_INIT:-${SCRIPT_DIR}/site-init.sh}"

run_site_overlay() {
  local src="$1" script
  if [[ "$src" =~ ^https?:// ]]; then
    script="$(mktemp)"
    echo "Fetching site overlay: ${src}"
    if ! curl -fsSL "$src" -o "$script"; then
      echo "WARN: could not fetch site overlay ${src} — skipping." >&2
      rm -f "$script"
      return
    fi
  elif [[ -f "$src" ]]; then
    script="$src"
  else
    echo "No site overlay (SITE_INIT='${src}' not found) — skipping server-specific setup."
    return
  fi

  echo "Running site overlay: ${src}"
  SERVER_ROLE="$SERVER_ROLE" \
  ALERT_EMAIL="$ALERT_EMAIL" \
  PUBLIC_IP="$PUBLIC_IP" \
  TAILSCALE_IP="$TAILSCALE_IP" \
  NEW_USER="$NEW_USER" \
    bash "$script"

  if [[ "$src" =~ ^https?:// ]]; then
    rm -f "$script"
  fi
}

run_site_overlay "$SITE_INIT"

# ─── Non-root user ───────────────────────────────────────────────────────────

if ! id "${NEW_USER}" &>/dev/null; then
  adduser --disabled-password --gecos "" "${NEW_USER}"
fi

usermod -aG docker "${NEW_USER}"
usermod -aG sudo "${NEW_USER}"

echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${NEW_USER}"
chmod 440 "/etc/sudoers.d/${NEW_USER}"

mkdir -p "/home/${NEW_USER}/.ssh"
echo "${SSH_PUBKEY}" >> "/home/${NEW_USER}/.ssh/authorized_keys"
chmod 700 "/home/${NEW_USER}/.ssh"
chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"

# ─── SSH lockdown ────────────────────────────────────────────────────────────
# Test non-root SSH access BEFORE disabling root login.

echo ""
echo "========================================================"
echo "IMPORTANT: Before continuing, open a NEW terminal and run:"
echo "  ssh -i <your-key> ${NEW_USER}@${PUBLIC_IP}"
echo "Confirm you can log in as ${NEW_USER} with sudo access."
echo "========================================================"
read -rp "Can you SSH in as ${NEW_USER}? [yes/no]: " SSH_TEST

if [[ "$SSH_TEST" != "yes" ]]; then
  echo "ERROR: Non-root SSH access not confirmed. Aborting SSH lockdown." >&2
  echo "The server is provisioned but root login is still enabled." >&2
  echo "Fix SSH access, then manually apply the sshd_config changes below." >&2
  exit 1
fi

cat > /etc/ssh/sshd_config.d/hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF

sshd -t  # validate config before reloading
systemctl reload sshd

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "=== Bootstrap complete ==="
echo "Server role      : ${SERVER_ROLE}"
echo "Public IP        : ${PUBLIC_IP}"
echo "Tailscale IP     : ${TAILSCALE_IP}"
echo "Dokploy version  : ${DOKPLOY_VERSION}"
echo ""
echo "Next steps:"
echo "  1. Open the Dokploy admin UI via Tailscale: http://dokploy-${SERVER_ROLE}.<tailnet>.ts.net:3000"
echo "  2. Create the admin account and enable 2FA."
echo "  3. Deploy your apps (host-specific steps live in your site overlay)."
echo ""
echo "Root login is now disabled. Use: ssh ${NEW_USER}@${PUBLIC_IP}"
