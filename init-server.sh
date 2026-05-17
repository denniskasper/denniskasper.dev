#!/usr/bin/env bash
# Bootstrap script for denniskasper.{dev,com} — single script for both servers.
# Usage: bash init-server.sh [--force]
# Run as root on a fresh Ubuntu 26.04 LTS VPS (Strato VPS for prod, Hetzner Cloud for dev).
set -euo pipefail

DOKPLOY_VERSION="v0.29.4"
ALERT_EMAIL="dennis.m.kasper@gmail.com"
GMAIL_SMTP_HOST="smtp.gmail.com"
GMAIL_SMTP_PORT="587"
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
read -rp "SSH public key for ${NEW_USER}: " SSH_PUBKEY
read -rp "Server role [dev|prod]: " SERVER_ROLE

if [[ "$SERVER_ROLE" != "dev" && "$SERVER_ROLE" != "prod" ]]; then
  echo "ERROR: role must be 'dev' or 'prod'" >&2
  exit 1
fi

read -rp "Tailscale auth key (ephemeral, from Tailscale admin console): " TS_AUTHKEY
read -rsp "Gmail SMTP app password (from pass smtp/gmail-app-password): " GMAIL_APP_PASSWORD
echo ""

CF_DNS_TOKEN=""
if [[ "$SERVER_ROLE" == "dev" ]]; then
  read -rsp "Cloudflare DNS API token (Zone:DNS:Edit on denniskasper.dev only): " CF_DNS_TOKEN
  echo ""
fi

# ─── Detect public IP ────────────────────────────────────────────────────────

PUBLIC_IP=$(curl -s --retry 3 ifconfig.me)
echo "Detected public IP: ${PUBLIC_IP}"

# ─── System updates ──────────────────────────────────────────────────────────

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban msmtp msmtp-mta mailutils \
  systemd-timesyncd \
  jq

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

# ─── Validate Cloudflare token scope (dev only) ───────────────────────────────

if [[ "$SERVER_ROLE" == "dev" && -n "$CF_DNS_TOKEN" ]]; then
  echo "Validating Cloudflare token scope..."
  CF_VERIFY=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CF_DNS_TOKEN}" \
    -H "Content-Type: application/json")
  CF_SUCCESS=$(echo "$CF_VERIFY" | jq -r '.success')
  if [[ "$CF_SUCCESS" != "true" ]]; then
    echo "ERROR: Cloudflare token verification failed." >&2
    echo "$CF_VERIFY" | jq . >&2
    exit 1
  fi
  echo "Cloudflare token verified OK."
fi

# ─── Docker Swarm ─────────────────────────────────────────────────────────────

docker swarm init --advertise-addr "${PUBLIC_IP}"

# ─── Tailscale ───────────────────────────────────────────────────────────────

curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey="${TS_AUTHKEY}" --ssh --hostname="$(hostname)"
TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP: ${TAILSCALE_IP}"

# ─── Docker Secrets ──────────────────────────────────────────────────────────

DOKPLOY_POSTGRES_PASSWORD=$(openssl rand -hex 32)
printf '%s' "${DOKPLOY_POSTGRES_PASSWORD}" | docker secret create POSTGRES_PASSWORD -

if [[ "$SERVER_ROLE" == "dev" && -n "$CF_DNS_TOKEN" ]]; then
  printf '%s' "${CF_DNS_TOKEN}" | docker secret create CF_DNS_TOKEN -
fi

# ─── Dokploy (pinned version, Docker Secrets mode) ───────────────────────────

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
# Port 3000 (Dokploy) intentionally NOT opened — Tailscale only

curl -fsSL "${UFW_DOCKER_URL}" -o /usr/local/bin/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install

ufw --force enable
systemctl enable ufw

# ─── fail2ban ────────────────────────────────────────────────────────────────

cat > /etc/fail2ban/jail.d/sshd.conf <<'EOF'
[sshd]
enabled  = true
maxretry = 5
bantime  = 1h
findtime = 10m
EOF

systemctl enable --now fail2ban

# ─── msmtp (Gmail SMTP relay) ────────────────────────────────────────────────

cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        gmail
host           ${GMAIL_SMTP_HOST}
port           ${GMAIL_SMTP_PORT}
from           ${ALERT_EMAIL}
user           ${ALERT_EMAIL}
password       ${GMAIL_APP_PASSWORD}

account default : gmail
EOF
chmod 600 /etc/msmtprc

# Route system mail through msmtp
ln -sf /usr/bin/msmtp /usr/sbin/sendmail

# Test mail delivery
echo "Subject: init-server.sh — mail test from $(hostname)" \
  | msmtp "${ALERT_EMAIL}" || echo "WARN: test mail failed, check /var/log/msmtp.log"

# ─── Disk hygiene cron ───────────────────────────────────────────────────────

cat > /etc/cron.daily/docker-prune <<'CRON'
#!/bin/sh
docker image prune -f
docker container prune -f
CRON
chmod +x /etc/cron.daily/docker-prune

cat > /etc/cron.d/disk-alert <<CRON
*/5 * * * * root \
  USED=\$(df / --output=pcent | tail -1 | tr -d ' %'); \
  [ "\$USED" -gt 80 ] && echo "Disk usage on \$(hostname) is \${USED}%%" \
    | mail -s "ALERT: disk > 80%% on \$(hostname)" ${ALERT_EMAIL}
CRON

# ─── Uptime check cron ───────────────────────────────────────────────────────

if [[ "$SERVER_ROLE" == "prod" ]]; then
  UPTIME_URLS="https://denniskasper.com https://leprechaun.denniskasper.com"
else
  UPTIME_URLS="https://denniskasper.dev"
fi

cat > /usr/local/bin/uptime-check <<SCRIPT
#!/bin/sh
for URL in ${UPTIME_URLS}; do
  HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "\$URL" || echo "000")
  if [ "\$HTTP_CODE" != "200" ]; then
    echo "\$URL returned HTTP \$HTTP_CODE" \
      | mail -s "ALERT: \$URL down on \$(hostname)" ${ALERT_EMAIL}
  fi
done
SCRIPT
chmod +x /usr/local/bin/uptime-check

cat > /etc/cron.d/uptime-check <<'CRON'
*/5 * * * * root /usr/local/bin/uptime-check
CRON

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
echo "  1. Open Dokploy admin UI via Tailscale: https://dokploy.<tailnet>.ts.net:3000"
echo "  2. Create admin account and enable 2FA."
if [[ "$SERVER_ROLE" == "dev" ]]; then
  echo "  3. Deploy a smoke-test app at hello.denniskasper.dev to verify wildcard cert."
else
  echo "  3. Deploy homepage: denniskasper.com"
  echo "  4. Deploy OpenLeprechaun: leprechaun.denniskasper.com"
fi
echo ""
echo "Root login is now disabled. Use: ssh ${NEW_USER}@${PUBLIC_IP}"
