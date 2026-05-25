#!/usr/bin/env bash
# Site overlay — invoked by init-server.sh once the base system (Docker, Dokploy,
# UFW, msmtp, crons) is in place. Carries host-specific *behaviour* but no baked-in
# URLs or owner facts, so this file stays generic and shareable.
#
# From init-server.sh (env): SERVER_ROLE, ALERT_EMAIL, PUBLIC_IP, TAILSCALE_IP, NEW_USER.
# Uptime targets (prod only) come from input, never hardcoding — either:
#   - pass UPTIME_URLS="https://a https://b" in the environment, or
#   - leave it unset and the overlay prompts for it interactively (blank = none).
# Deploy webhook tunnel (any role): set DEPLOY_TUNNEL_TOKEN (a Cloudflare tunnel
#   connector token) to install cloudflared non-interactively; blank = prompt/skip.
set -euo pipefail

SERVER_ROLE="${SERVER_ROLE:-int}"
UPTIME_URLS="${UPTIME_URLS:-}"

# ─── Uptime monitoring (prod only — it emails alerts, and int has no mail relay) ──
if [[ "$SERVER_ROLE" == "prod" ]]; then
  # Take URLs from the environment; if none and we have a terminal, ask.
  if [[ -z "$UPTIME_URLS" && -t 0 ]]; then
    read -rp "URLs to monitor for uptime (space-separated, blank = none): " UPTIME_URLS
  fi

  if [[ -n "$UPTIME_URLS" ]]; then
    : "${ALERT_EMAIL:?uptime monitoring needs ALERT_EMAIL from init-server.sh}"

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
0 * * * * root /usr/local/bin/uptime-check
CRON
    echo "Site overlay: installed uptime-check for ${UPTIME_URLS}"
  else
    echo "Site overlay: no URLs given — skipping uptime monitoring."
  fi
fi

# ─── Deploy webhook tunnel (optional, any role) ───────────────────────────────
# A Cloudflare named tunnel (created in the Zero Trust dashboard, with a public
# hostname path-scoped to the deploy webhook there) exposes ONLY the CI/CD
# webhook publicly while the Dokploy panel stays Tailscale-only. Paste its
# connector token to install the connector non-interactively; blank = skip.
DEPLOY_TUNNEL_TOKEN="${DEPLOY_TUNNEL_TOKEN:-}"
if [[ -z "$DEPLOY_TUNNEL_TOKEN" && -t 0 ]]; then
  read -rsp "Cloudflare tunnel token for the deploy webhook (blank = skip): " DEPLOY_TUNNEL_TOKEN
  echo ""
fi
if [[ -n "$DEPLOY_TUNNEL_TOKEN" ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    # .deb is reliable on brand-new Ubuntu where the apt repo may lack the codename.
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
    dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
  fi
  cloudflared service install "$DEPLOY_TUNNEL_TOKEN"
  echo "Site overlay: cloudflared deploy-tunnel connector installed (routing configured in Cloudflare)."
fi

# ─── Post-bootstrap reminder ──────────────────────────────────────────────────
echo ""
echo "Site overlay (${SERVER_ROLE}) done. Deploy your apps via the Dokploy UI."
if [[ "$SERVER_ROLE" == "int" ]]; then
  echo "Wildcard TLS, if you need it, is a manual Dokploy step: Traefik -> add a"
  echo "Cloudflare DNS-01 resolver + CF_DNS_API_TOKEN (scoped Zone:DNS:Edit)."
fi
