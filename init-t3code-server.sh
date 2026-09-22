#!/usr/bin/env bash
# Installs a T3 Code server on a machine already provisioned by init-server.sh, and
# publishes it over Tailscale Serve so it is reachable from the tailnet and nowhere
# else. Run as the user who will own it — not as root, and not during the bootstrap.
#
# Usage: bash init-t3code-server.sh
# Quickstart:
#   curl -fsSL https://raw.githubusercontent.com/denniskasper/server-bootstrap/main/init-t3code-server.sh -o init-t3code-server.sh && \
#     bash init-t3code-server.sh
#
# Why this is separate from init-server.sh rather than a SITE_INIT overlay: the
# overlay runs as root, mid-bootstrap, unattended. Every important step here is the
# opposite. `t3 service install` creates a systemd *user* service, so running it as
# root produces one with no access to the user's data or provider logins. Three of the
# logins need a human with a second device. And a git identity belongs to a person,
# not a machine.
#
# Inputs, env-or-prompt, same idiom as init-server.sh:
#   GIT_USER_NAME  GIT_USER_EMAIL  TS_SERVE_PORT
set -euo pipefail

NODE_MAJOR="24"
T3_LOCAL_PORT="3773"   # what `t3 serve` binds on loopback

# ─── Preconditions ───────────────────────────────────────────────────────────

if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERROR: run this as the user who will own the server, not as root." >&2
  echo "       t3 installs a systemd *user* service; a root install would create one" >&2
  echo "       with no access to this user's ~/.t3 or provider logins." >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "ERROR: tailscale is not installed. Run init-server.sh on this machine first." >&2
  exit 1
fi

# ─── Inputs ──────────────────────────────────────────────────────────────────

ask() {
  local var="$1" prompt="$2"
  if [[ -n "${!var:-}" ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: ${var} is unset and there is no terminal to prompt on." >&2
    exit 1
  fi
  read -rp "$prompt" "$var"
}

echo ""
echo "=== init-t3code-server.sh ==="
echo ""

# A git identity is a person's, not a machine's, so it is asked for rather than
# assumed. Agents on this box will commit under whatever is set here.
ask GIT_USER_NAME  "Git author name (e.g. Ada Lovelace): "
ask GIT_USER_EMAIL "Git author email: "

# Traefik publishes :443 on a Dokploy host, so Serve cannot have it. 8443 keeps out
# of its way; change it only if something else already holds that port.
TS_SERVE_PORT="${TS_SERVE_PORT:-8443}"

# ─── Node, and the npm version that actually works ───────────────────────────
# init-server.sh installs no Node runtime; the T3 server needs
# ^22.16 || ^23.11 || >=24.10.

if ! command -v node >/dev/null 2>&1; then
  echo "Installing Node ${NODE_MAJOR} from NodeSource..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs
fi
echo "Node: $(node --version)"

# NodeSource ships npm 11.x, which SILENTLY SKIPS optional dependencies. The t3
# package delivers its ~206 MB platform binary that way, so the install "succeeds"
# and then every t3 command prints:
#
#   no T3 Code CLI build is available for this platform (linux-x64).
#   Supported platforms: ..., linux-x64, ...
#
# — naming your platform as both unsupported and supported, because an optional
# dependency that fails is not an error. npm 12 installs it correctly. Nobody guesses
# this from the message, so the upgrade is unconditional rather than advisory.
NPM_MAJOR="$(npm --version | cut -d. -f1)"
if [[ "$NPM_MAJOR" -lt 12 ]]; then
  echo "Upgrading npm ${NPM_MAJOR}.x -> 12 (11.x silently skips t3's platform binary)..."
  sudo npm install -g npm@12
fi
echo "npm: $(npm --version)"

# ─── git and gh ──────────────────────────────────────────────────────────────

sudo apt-get install -y git

# Ubuntu's gh is far behind: 2.45/2.46 against the 2.81 T3 Code needs to report
# sign-in status. GitHub's own repository is keyed on `stable main` with no release
# codename, so unlike Docker's and NodeSource's it cannot lag a new Ubuntu.
if ! command -v gh >/dev/null 2>&1; then
  echo "Installing gh from GitHub's apt repository..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt-get update -q
  sudo apt-get install -y gh
fi
echo "git: $(git --version)   gh: $(gh --version | head -1)"

git config --global user.name  "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"
git config --global init.defaultBranch main

# ─── Provider CLIs ───────────────────────────────────────────────────────────
# Installed as this user, into ~/.local/bin. Ubuntu's stock ~/.profile already adds
# that directory when it exists, so no PATH edit is needed — both installers offer to
# append to ~/.bashrc, which Ubuntu skips for non-interactive shells anyway.

command -v claude >/dev/null 2>&1 || curl -fsSL https://claude.ai/install.sh | bash
command -v codex  >/dev/null 2>&1 || curl -fsSL https://chatgpt.com/codex/install.sh | sh
command -v grok   >/dev/null 2>&1 || curl -fsSL https://x.ai/cli/install.sh | bash

export PATH="$HOME/.local/bin:$PATH"

# ─── T3 Code ─────────────────────────────────────────────────────────────────
# Installed globally as root: NodeSource's prefix is root-owned, and /usr/bin is on
# every PATH including the minimal one a systemd service gets. T3 keeps its own
# versions under ~/.t3/runtime/versions, so root owning the launcher costs nothing.

sudo npm install -g t3@latest

# Verify the platform binary actually arrived rather than trusting a silent success.
if ! ls "$(npm root -g)"/t3/node_modules/@t3code/ >/dev/null 2>&1; then
  echo "ERROR: t3 installed but its platform binary is missing." >&2
  echo "       This is the npm optional-dependency failure described above." >&2
  echo "       Check 'npm --version' is 12+, then reinstall." >&2
  exit 1
fi
echo "t3: $(t3 --version)"

# ─── Service ─────────────────────────────────────────────────────────────────

t3 service install

# A systemd *user* service stops at logout and does not start at boot unless the
# account lingers. This matters on a box that reboots itself for unattended upgrades:
# without it, T3 Code is simply gone one morning with nothing to explain why.
sudo loginctl enable-linger "$USER"

# ─── Tailscale Serve ─────────────────────────────────────────────────────────
# The backend binds 127.0.0.1 only. Serve is the sole route in, and it is tailnet-only
# — there is no public listener to firewall off. init-server.sh sets the Tailscale
# operator, so this needs no sudo; on a box provisioned before that change, run
# `sudo tailscale set --operator=$USER` once.

tailscale serve --https="${TS_SERVE_PORT}" --bg "http://127.0.0.1:${T3_LOCAL_PORT}"

# ─── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "=== T3 Code server installed ==="
echo ""
echo "  Service : $(systemctl --user is-active t3code.service)"
echo "  Linger  : $(loginctl show-user "$USER" --property=Linger)"
echo ""
# Serve knows the real MagicDNS URL; deriving it from the hostname would only guess.
tailscale serve status

cat <<EOF

Four logins still need a human and a second device:

  gh auth login     # HTTPS, and yes to authenticating git
  claude            # sign in
  codex             # choose "Sign in with Device Code" — the ChatGPT option
                    # starts a callback server on this machine's loopback, which
                    # a browser elsewhere cannot reach without an SSH tunnel
  grok              # same constraint: prefer a device-code flow over anything
                    # that wants to open a browser here

Then pair a client:

  t3 pair --tailscale --tailscale-serve-port ${TS_SERVE_PORT}

To undo the Serve mapping, which is state separate from the systemd unit:

  tailscale serve --https=${TS_SERVE_PORT} off
EOF
