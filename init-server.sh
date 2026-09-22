#!/usr/bin/env bash
# Generic Dokploy server bootstrap — hardens a fresh Ubuntu LTS VPS and installs
# Docker Swarm + Dokploy. Holds no host- or owner-specific facts; anything tied
# to a particular server (app deploy steps, owner policy, etc.) lives in an
# optional site overlay — see the "Site-specific overlay" section. This repo
# ships no overlay; the extension point stays for whoever needs one.
# Usage: bash init-server.sh [--force]   (run as root on a fresh Ubuntu LTS VPS)
# Quickstart (fetch + run from main):
#   curl -fsSL https://raw.githubusercontent.com/denniskasper/server-bootstrap/main/init-server.sh -o init-server.sh && \
#     bash init-server.sh
# Every input can also be supplied in the environment (see "Inputs"), so the
# whole run can go unattended — rehearse it on a throwaway VM before pointing
# it at a box you care about. This script is NOT idempotent; see "Safety check".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ─── Inputs ───────────────────────────────────────────────────────────────────
# Every value below can be supplied in the environment; anything left unset is
# prompted for. Supplying all of them lets the whole script run unattended,
# which is what makes a rehearsal on a throwaway VM cheap to repeat.
#
#   NEW_USER  SSH_PUBKEY  TS_HOSTNAME  TS_AUTHKEY  ALERT_EMAIL  SMTP_PASSWORD
#   SSH_TEST  (the pre-lockdown confirmation — see "SSH lockdown")
#
# With no terminal to prompt on, a missing value is a named error rather than a
# read that blocks forever.

ask() {
  local var="$1" prompt="$2" hidden="${3:-}"
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: ${var} is unset and there is no terminal to prompt on." >&2
    echo "       Set ${var} in the environment for an unattended run." >&2
    exit 1
  fi
  if [[ -n "$hidden" ]]; then
    read -rsp "$prompt" "$var"
    echo ""
  else
    read -rp "$prompt" "$var"
  fi
}

# True while a value still has to be asked for — gates the on-screen help so an
# unattended run does not print instructions nobody is there to read.
prompting_for() { [[ -z "${!1:-}" && -t 0 ]]; }

echo ""
echo "=== init-server.sh — Dokploy server bootstrap ==="
echo ""

ask NEW_USER "Username to create (e.g. deploy): "

# SSH_PUBKEY is the operator's *public* key, which lives on their LOCAL machine
# (the one they SSH from) — not on this server. Retrieve it locally with:
#   cat ~/.ssh/id_ed25519.pub   (or ~/.ssh/id_rsa.pub)
# No key yet? Create one locally with `ssh-keygen -t ed25519`, then cat the .pub.
if prompting_for SSH_PUBKEY; then
  echo ""
  echo "Paste the SSH PUBLIC key for ${NEW_USER} — from your LOCAL machine, not this server."
  echo "  Print it locally:  cat ~/.ssh/id_ed25519.pub   (or ~/.ssh/id_rsa.pub)"
  echo "  No key yet?        ssh-keygen -t ed25519   then cat the .pub file"
  echo "  Use the .pub (starts 'ssh-ed25519'/'ssh-rsa') — never the private key."
fi
ask SSH_PUBKEY "SSH public key: "

# The machine's name is an input, not a derived value — this script holds no
# host-specific facts. It becomes the OS hostname, the Swarm node name and the
# tailnet node name, so the box has one name everywhere.
if prompting_for TS_HOSTNAME; then
  echo ""
fi
ask TS_HOSTNAME "Hostname for this machine (e.g. web-01): "

# TS_AUTHKEY is generated in the Tailscale admin console (it is NOT a password).
# Generate a *persistent* key with expiry disabled: this node is not disposable,
# and an ephemeral node that drops during an outage takes the Dokploy panel with it.
if prompting_for TS_AUTHKEY; then
  echo ""
  echo "Tailscale auth key — generate one in the admin console (not a password):"
  echo "  https://login.tailscale.com/admin/settings/keys  ->  'Generate auth key'"
  echo "  Leave 'Ephemeral' OFF and disable key expiry on the node. Starts 'tskey-auth-'."
fi
ask TS_AUTHKEY "Tailscale auth key (input hidden): " hidden

# Mail relay credentials. The box watches what it can observe about itself while
# alive (disk); liveness is monitored externally, off the machine.
ask ALERT_EMAIL   "Alert / SMTP sender email (receives disk alerts): "
ask SMTP_PASSWORD "SMTP app password for ${ALERT_EMAIL} (input hidden): " hidden

# ─── Validate the inputs ─────────────────────────────────────────────────────
# Cheap checks, but they matter more now that values can arrive from the
# environment: an unattended run has no one watching for an obvious typo.

if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "ERROR: NEW_USER must be a valid Linux username: lowercase, starting with a" >&2
  echo "       letter or underscore, at most 32 characters." >&2
  exit 1
fi

# Catches the classic footgun of pasting the PRIVATE key, which would otherwise
# land silently in authorized_keys and lock the operator out at the SSH test.
if [[ ! "$SSH_PUBKEY" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-ssh-|sk-ecdsa-) ]]; then
  echo "ERROR: SSH_PUBKEY does not look like a public key. It must begin with" >&2
  echo "       'ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-' or an 'sk-' variant." >&2
  echo "       If it begins '-----BEGIN', that is your PRIVATE key — use the .pub." >&2
  exit 1
fi

# Validate as a DNS label rather than letting Tailscale silently sanitise it —
# a surprise rename breaks the MagicDNS URL this script prints at the end. The
# same rule is what a Linux hostname needs, so one check covers both uses.
if [[ ! "$TS_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ || ${#TS_HOSTNAME} -gt 63 ]]; then
  echo "ERROR: hostname must be a DNS label: lowercase a-z, 0-9 and '-'," >&2
  echo "       not starting or ending with '-', at most 63 characters." >&2
  exit 1
fi

if [[ "$ALERT_EMAIL" != *@*.* ]]; then
  echo "ERROR: ALERT_EMAIL does not look like an email address: ${ALERT_EMAIL}" >&2
  exit 1
fi

# ─── Hostname ────────────────────────────────────────────────────────────────
# Cloud images ship a generic name — "ubuntu" on most of them — which makes every
# alert mail and every `docker node ls` ambiguous the moment there is more than
# one machine. Give the box one name and use it everywhere.
#
# This must happen BEFORE Docker starts: `docker swarm init` takes the node name
# from the hostname, and renaming afterwards does not rename the node.

hostnamectl set-hostname "${TS_HOSTNAME}"

# Debian and Ubuntu resolve the local hostname through 127.0.1.1. Without this,
# sudo prints "unable to resolve host" on every single invocation.
if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t${TS_HOSTNAME}/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "${TS_HOSTNAME}" >> /etc/hosts
fi
echo "Hostname: ${TS_HOSTNAME}"

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

apt-get install -yq msmtp msmtp-mta mailutils

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

# ─── Swap ────────────────────────────────────────────────────────────────────
# VPS images frequently ship with no swap at all. Docker image builds spike well
# past steady-state memory, and with no swap the OOM killer takes the build — or
# something that matters more — with no warning and no log entry worth reading.
# A small file is enough; swappiness 10 keeps it an overflow valve rather than a
# paging strategy. SWAP_SIZE=0 skips this entirely.

SWAP_SIZE="${SWAP_SIZE:-4G}"
if [[ "$SWAP_SIZE" == "0" ]]; then
  echo "Swap: SWAP_SIZE=0 — skipping."
elif swapon --show --noheadings | grep -q .; then
  echo "Swap: already active — leaving it alone."
else
  if ! fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
    # Some filesystems refuse fallocate for swap; write the file out instead.
    dd if=/dev/zero of=/swapfile status=none \
      bs=1M count="$(( $(numfmt --from=iec "$SWAP_SIZE") / 1048576 ))"
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl -q -w vm.swappiness=10
  echo "Swap: ${SWAP_SIZE} at /swapfile, swappiness 10."
fi

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
# Deterministic node name → predictable MagicDNS URL instead of the cloud image's
# default hostname.
tailscale up --authkey="${TS_AUTHKEY}" --ssh --hostname="${TS_HOSTNAME}"
TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP: ${TAILSCALE_IP}"

# ─── Dokploy (latest release) ────────────────────────────────────────────────

echo "Installing the latest Dokploy release..."

# To a temp file rather than piped into bash, so a stopped run leaves something
# readable on disk. Nothing here inspects it automatically — do that yourself if
# you care, by fetching the URL before running this script.
DOKPLOY_INSTALL_SCRIPT=$(mktemp)
curl -fsSL "https://dokploy.com/install.sh" -o "${DOKPLOY_INSTALL_SCRIPT}"
# DOKPLOY_VERSION is left unset on purpose — install.sh then takes the newest
# release. The trade-off: a rebuild months from now yields a different Dokploy,
# so this bootstrap is not byte-for-byte reproducible over time.
bash "${DOKPLOY_INSTALL_SCRIPT}"
rm -f "${DOKPLOY_INSTALL_SCRIPT}"

# Apply Docker Secrets migration (removes legacy hardcoded postgres password)
echo "Applying Dokploy Docker Secrets fix..."
DOKPLOY_SEC_SCRIPT=$(mktemp)
curl -fsSL "https://dokploy.com/security/0.26.6.sh" -o "${DOKPLOY_SEC_SCRIPT}"
bash "${DOKPLOY_SEC_SCRIPT}"
rm -f "${DOKPLOY_SEC_SCRIPT}"

# Disable Dokploy's built-in auto-updater. "Install the latest at bootstrap" and
# "let Dokploy upgrade itself unattended forever after" are separate decisions;
# panel upgrades stay deliberate.
docker service update \
  --env-add SKIP_AUTO_UPDATE=true \
  dokploy 2>/dev/null || true

# Report what actually got installed, read back from the running service's image
# tag — there is no constant to echo any more.
DOKPLOY_IMAGE=$(docker service inspect dokploy \
  --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)
DOKPLOY_IMAGE="${DOKPLOY_IMAGE%%@*}"          # drop any @sha256: digest
DOKPLOY_VERSION="${DOKPLOY_IMAGE##*:}"        # tag after the last colon
if [[ -z "$DOKPLOY_VERSION" || "$DOKPLOY_VERSION" == "$DOKPLOY_IMAGE" ]]; then
  DOKPLOY_VERSION="unknown (could not read the dokploy service image tag)"
fi

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

# Let external HTTP/HTTPS through to whatever container publishes those ports.
#
# The obvious form of this is `ufw-docker allow dokploy-traefik 80`, which writes a
# rule naming the container's current address. Those addresses are not stable: Dokploy
# recreates dokploy-traefik on updates and on any change to its environment or ports,
# and it can come back on a different one. The rule then matches nothing, every public
# site times out, and the tailnet keeps answering — so it reads as a DNS or routing
# fault rather than a firewall one. `ufw-docker allow` cannot even repair it, because
# it only knows the networks `docker inspect` lists, and a container attached to an
# overlay network alone publishes through docker_gwbridge, which is not among them.
#
# Naming the port instead of the container removes the failure entirely. Only one
# container can publish a given host port, so "allow forwarded traffic to port 80" is
# "allow whatever serves port 80" — Traefik, by construction rather than by
# configuration. A container publishing anything else is still blocked, which is what
# ufw-docker is installed for.
ufw route allow proto tcp from any to any port 80  comment "HTTP to whatever publishes it"
ufw route allow proto tcp from any to any port 443 comment "HTTPS to whatever publishes it"

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

# ─── Disk hygiene cron ───────────────────────────────────────────────────────

cat > /etc/cron.daily/docker-prune <<'CRON'
#!/bin/sh
docker image prune -f
docker container prune -f

# The BuildKit cache is what actually fills the disk on a box that builds its own
# images, and neither prune above touches it. Docker 28 renamed the size-cap flag
# from --keep-storage to --reserved-space; try the current name first, then the
# old one, then fall back to an age filter if neither is understood.
docker builder prune -f --reserved-space 5g 2>/dev/null \
  || docker builder prune -f --keep-storage 5g 2>/dev/null \
  || docker builder prune -f --filter until=168h

# Volumes are deliberately never pruned — that is where the data lives.
CRON
chmod +x /etc/cron.daily/docker-prune

# Disk-full email alert. A condition the box can observe about itself while it is
# alive — unlike liveness, which is monitored externally.
cat > /etc/cron.d/disk-alert <<CRON
*/5 * * * * root \
  USED=\$(df / --output=pcent | tail -1 | tr -d ' %'); \
  [ "\$USED" -gt 80 ] && echo "Disk usage on \$(hostname) is \${USED}%%" \
    | mail -s "ALERT: disk > 80%% on \$(hostname)" ${ALERT_EMAIL}
CRON

# ─── Site-specific overlay (optional) ────────────────────────────────────────
# Everything tied to a *particular* server — app deploy steps, owner-specific
# policy — is kept OUT of this generic bootstrap. Point at
# an overlay with SITE_INIT (a URL or a local path); it defaults to a site-init.sh
# next to this script. This repo ships no overlay, so the default finds nothing and
# the step is skipped — the extension point costs nothing and stays.
# The overlay runs here, after the base system is in place, receiving
# ALERT_EMAIL/PUBLIC_IP/TAILSCALE_IP/TS_HOSTNAME/NEW_USER.

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
  ALERT_EMAIL="$ALERT_EMAIL" \
  PUBLIC_IP="$PUBLIC_IP" \
  TAILSCALE_IP="$TAILSCALE_IP" \
  TS_HOSTNAME="$TS_HOSTNAME" \
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

# This script runs `tailscale up` as root, so tailscaled's state is root-owned and
# every `tailscale` subcommand that writes — `serve`, `funnel`, `set` — is denied to
# anyone else. That is a papercut the bootstrap itself creates: the account it just
# made is the one that will actually use the machine.
#
# It matters most for anything running AS that user rather than as root. A systemd
# *user* service that wants to publish itself over Tailscale Serve cannot sudo, so
# without this it fails at runtime with "Access denied: serve config denied" rather
# than at setup, which is a considerably worse place to find out.
#
# Reading remains unrestricted either way; this only grants the writes. Run after the
# account exists, because tailscaled resolves the name.
tailscale set --operator="${NEW_USER}"

echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${NEW_USER}"
chmod 440 "/etc/sudoers.d/${NEW_USER}"

mkdir -p "/home/${NEW_USER}/.ssh"
echo "${SSH_PUBKEY}" >> "/home/${NEW_USER}/.ssh/authorized_keys"
chmod 700 "/home/${NEW_USER}/.ssh"
chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh"

# ─── SSH lockdown ────────────────────────────────────────────────────────────
# Test non-root SSH access BEFORE disabling root login.
#
# SSH_TEST=yes in the environment skips the pause, which is what allows an
# unattended rehearsal run to complete. Do not set it on a box you cannot
# afford to be locked out of: the whole point of the pause is that a human
# proved the new key works while root login was still available.

if prompting_for SSH_TEST; then
  echo ""
  echo "========================================================"
  echo "IMPORTANT: Before continuing, open a NEW terminal and run:"
  echo "  ssh ${NEW_USER}@${PUBLIC_IP}"
  echo "  sudo -n true && echo OK"
  echo ""
  echo "Test sudo with 'sudo -n true', NOT 'sudo -v'. On sudo-rs (Ubuntu 26.04+)"
  echo "-v authenticates even with NOPASSWD, and this account has no password."
  echo "========================================================"
elif [[ -n "${SSH_TEST:-}" ]]; then
  echo ""
  echo "WARNING: SSH_TEST='${SSH_TEST}' came from the environment — nobody verified" >&2
  echo "         non-root SSH access before this lockdown." >&2
fi
ask SSH_TEST "Can you SSH in as ${NEW_USER}? [yes/no]: "

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
echo "Hostname         : ${TS_HOSTNAME}   (OS, Swarm node and tailnet node)"
echo "Public IP        : ${PUBLIC_IP}"
echo "Tailscale IP     : ${TAILSCALE_IP}"
echo "Dokploy version  : ${DOKPLOY_VERSION}"
echo ""
echo "Next steps:"
echo "  1. Open the Dokploy admin UI via Tailscale: http://${TS_HOSTNAME}.<tailnet>.ts.net:3000"
echo "  2. Create the admin account and enable 2FA."
echo "  3. Deploy your apps from the Dokploy UI."
echo ""
echo "Root login is now disabled. Use: ssh ${NEW_USER}@${PUBLIC_IP}"
