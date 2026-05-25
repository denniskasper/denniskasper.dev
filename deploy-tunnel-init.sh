#!/usr/bin/env bash
# deploy-tunnel-init.sh — stand up the locally-managed cloudflared tunnel that
# exposes ONLY the Dokploy deploy webhook publicly, while the admin panel stays
# Tailscale-only. This is the locally-managed (CLI) tunnel — NOT the Zero-Trust
# connector-token path (that path forces the ZT "choose a plan" onboarding).
#
# Run as root on the target server (do `sudo -i` first), AFTER init-server.sh
# has installed Dokploy (listening on localhost:3000). Idempotent: safe to re-run.
#
# AUTOMATION NOTE — the only possibly-interactive step is `cloudflared tunnel
# login` (opens a browser to mint ~/.cloudflared/cert.pem). To make this run
# 100% non-interactive, drop an existing account cert.pem at
# /root/.cloudflared/cert.pem BEFORE running — e.g. copy it from the int box,
# the same Cloudflare account authorizes both the .dev and .com zones:
#     scp root@<int>:/root/.cloudflared/cert.pem /root/.cloudflared/cert.pem
# (cert.pem is an account-scoped credential — treat it like a secret.)
#
# Params (env-overridable):
#   ROLE=prod|int     -> picks default hostname + tunnel name (default: prod)
#   TUNNEL_NAME       -> default: dokploy-${ROLE}
#   DEPLOY_HOSTNAME   -> default: deploy.denniskasper.com  (.dev when ROLE=int)
#   SERVICE_URL       -> default: http://localhost:3000
#   WEBHOOK_PATH      -> default: /api/deploy/github
set -euo pipefail

# ─── Params ──────────────────────────────────────────────────────────────────
ROLE="${ROLE:-prod}"
case "$ROLE" in
  prod) _DEFAULT_HOST="deploy.denniskasper.com" ;;
  int)  _DEFAULT_HOST="deploy.denniskasper.dev" ;;
  *)    _DEFAULT_HOST="" ;;
esac
TUNNEL_NAME="${TUNNEL_NAME:-dokploy-${ROLE}}"
DEPLOY_HOSTNAME="${DEPLOY_HOSTNAME:-${_DEFAULT_HOST}}"
SERVICE_URL="${SERVICE_URL:-http://localhost:3000}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/api/deploy/github}"

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (do 'sudo -i' first)." >&2; exit 1; }
[[ -n "$DEPLOY_HOSTNAME" ]] || { echo "ERROR: DEPLOY_HOSTNAME unset and ROLE='$ROLE' has no default — set DEPLOY_HOSTNAME." >&2; exit 1; }

CFD_DIR="${HOME}/.cloudflared"
ETC_DIR="/etc/cloudflared"
ZONE="${DEPLOY_HOSTNAME#deploy.}"

echo ""
echo "=== deploy-tunnel-init.sh ==="
echo "Role            : ${ROLE}"
echo "Tunnel name     : ${TUNNEL_NAME}"
echo "Public hostname : ${DEPLOY_HOSTNAME}  (zone: ${ZONE})"
echo "Webhook         : ${WEBHOOK_PATH}  ->  ${SERVICE_URL}"
echo ""

# ─── Install cloudflared (.deb — reliable on fresh Ubuntu) ─────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
  ARCH="$(dpkg --print-architecture)"   # amd64 | arm64
  echo "Installing cloudflared (${ARCH})..."
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb" -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb
  rm -f /tmp/cloudflared.deb
else
  echo "cloudflared present: $(cloudflared --version 2>/dev/null | head -n1)"
fi

# ─── Ensure an account cert.pem (only step that may prompt) ────────────────────
if [[ ! -f "${CFD_DIR}/cert.pem" ]]; then
  echo ""
  echo ">>> No ${CFD_DIR}/cert.pem — running 'cloudflared tunnel login'."
  echo ">>> Open the URL it prints in a browser and authorize the '${ZONE}' zone."
  echo ">>> (Skip this next time by placing a cert.pem at ${CFD_DIR}/cert.pem first.)"
  echo ""
  mkdir -p "$CFD_DIR"
  cloudflared tunnel login
else
  echo "Using existing account cert: ${CFD_DIR}/cert.pem"
fi

# ─── Create the tunnel (idempotent) ────────────────────────────────────────────
tunnel_uuid() { cloudflared tunnel list 2>/dev/null | awk -v n="$TUNNEL_NAME" 'NR>1 && $2==n {print $1}'; }

UUID="$(tunnel_uuid || true)"
if [[ -z "$UUID" ]]; then
  echo "Creating tunnel '${TUNNEL_NAME}'..."
  cloudflared tunnel create "$TUNNEL_NAME"
  UUID="$(tunnel_uuid || true)"
else
  echo "Tunnel '${TUNNEL_NAME}' already exists (${UUID}) — reusing."
fi
[[ -n "$UUID" ]] || { echo "ERROR: could not resolve tunnel UUID." >&2; exit 1; }

CRED_SRC="${CFD_DIR}/${UUID}.json"
[[ -f "$CRED_SRC" ]] || { echo "ERROR: credentials file ${CRED_SRC} missing." >&2; exit 1; }

# ─── Route DNS (creates a PROXIED CNAME ${DEPLOY_HOSTNAME} -> <uuid>.cfargotunnel.com) ─
# --overwrite-dns replaces any pre-existing record at that exact name (a wildcard
# *-record is a different name and is left untouched; the explicit record wins).
echo "Routing DNS: ${DEPLOY_HOSTNAME} -> ${TUNNEL_NAME}"
cloudflared tunnel route dns --overwrite-dns "$TUNNEL_NAME" "$DEPLOY_HOSTNAME"

# ─── Write path-scoped config + creds under /etc/cloudflared ───────────────────
# The systemd service runs as root and finds /etc/cloudflared/config.yml; keep
# the credentials file beside it (mode 600).
mkdir -p "$ETC_DIR"
install -m 600 "$CRED_SRC" "${ETC_DIR}/${UUID}.json"

cat > "${ETC_DIR}/config.yml" <<EOF
tunnel: ${UUID}
credentials-file: ${ETC_DIR}/${UUID}.json

# Expose ONLY the deploy webhook; everything else returns 404. The panel (:3000)
# is never reachable except via this one path — admin stays Tailscale-only.
ingress:
  - hostname: ${DEPLOY_HOSTNAME}
    path: ${WEBHOOK_PATH}
    service: ${SERVICE_URL}
  - service: http_status:404
EOF

# ─── Validate config + path-scoping locally (no network needed) ────────────────
echo "Validating ingress rules..."
cloudflared --config "${ETC_DIR}/config.yml" tunnel ingress validate
echo "  rule for ${WEBHOOK_PATH} (expect ${SERVICE_URL}):"
cloudflared --config "${ETC_DIR}/config.yml" tunnel ingress rule "https://${DEPLOY_HOSTNAME}${WEBHOOK_PATH}" || true
echo "  rule for / (expect http_status:404):"
cloudflared --config "${ETC_DIR}/config.yml" tunnel ingress rule "https://${DEPLOY_HOSTNAME}/" || true

# ─── Install / restart the systemd service (idempotent) ────────────────────────
if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared\.service'; then
  echo "cloudflared service already installed — restarting."
  systemctl daemon-reload
  systemctl restart cloudflared
else
  echo "Installing cloudflared systemd service..."
  cloudflared service install
fi
systemctl enable cloudflared >/dev/null 2>&1 || true
sleep 2
systemctl --no-pager --full status cloudflared 2>/dev/null | head -n 12 || true

# ─── External verification (best-effort; edge/DNS may lag a few seconds) ───────
echo ""
echo "Verifying public endpoint (retrying up to ~60s)..."
check() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || echo 000; }
ROOT_CODE=000; HOOK_CODE=000
for _ in $(seq 1 12); do
  ROOT_CODE="$(check "https://${DEPLOY_HOSTNAME}/")"
  HOOK_CODE="$(check "https://${DEPLOY_HOSTNAME}${WEBHOOK_PATH}")"
  [[ "$ROOT_CODE" == "404" && "$HOOK_CODE" == "401" ]] && break
  sleep 5
done
echo "  GET /                -> ${ROOT_CODE}  (expect 404)"
echo "  GET ${WEBHOOK_PATH}  -> ${HOOK_CODE}  (expect 401 'Missing signature header')"
if [[ "$ROOT_CODE" == "404" && "$HOOK_CODE" == "401" ]]; then
  echo "  OK — tunnel is live and path-scoped."
else
  echo "  NOTE: not yet confirmed (edge/DNS may still be settling). Re-check:"
  echo "    curl -i https://${DEPLOY_HOSTNAME}/ ; curl -i https://${DEPLOY_HOSTNAME}${WEBHOOK_PATH}"
fi

echo ""
echo "=== Done. Next: set the Dokploy GitHub App Webhook URL to ==="
echo "    https://${DEPLOY_HOSTNAME}${WEBHOOK_PATH}"
echo ""
