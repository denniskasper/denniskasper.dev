#!/usr/bin/env bash
# Site overlay for denniskasper.{com,dev} — invoked by init-server.sh once the
# base system (Docker, Dokploy, UFW, msmtp, crons) is in place. Keeps host- and
# owner-specific setup out of the generic bootstrap so init-server.sh stays
# reusable on any server.
#
# Exported by init-server.sh: SERVER_ROLE, ALERT_EMAIL, PUBLIC_IP, TAILSCALE_IP,
# NEW_USER. (ALERT_EMAIL is empty on dev, which sends no mail.)
set -euo pipefail

SERVER_ROLE="${SERVER_ROLE:-dev}"

# ─── Uptime monitoring (prod only — dev is a playground, sends no mail) ───────
if [[ "$SERVER_ROLE" == "prod" ]]; then
  : "${ALERT_EMAIL:?prod overlay needs ALERT_EMAIL from init-server.sh}"
  UPTIME_URLS="https://denniskasper.com https://leprechaun.denniskasper.com"

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
  echo "Site overlay: installed uptime-check for ${UPTIME_URLS}"
fi

# ─── App deploy reminders ────────────────────────────────────────────────────
echo ""
echo "Site overlay (${SERVER_ROLE}) — app deploy targets:"
if [[ "$SERVER_ROLE" == "dev" ]]; then
  echo "  - hello.denniskasper.dev (smoke-test the wildcard cert)"
  echo "  Wildcard TLS is manual: in Dokploy -> Traefik, add a Cloudflare DNS-01"
  echo "  resolver + CF_DNS_API_TOKEN (scoped Zone:DNS:Edit). Not bootstrapped."
else
  echo "  - denniskasper.com (homepage)"
  echo "  - leprechaun.denniskasper.com (OpenLeprechaun)"
fi
