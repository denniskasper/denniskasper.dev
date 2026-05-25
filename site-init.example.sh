#!/usr/bin/env bash
# Site overlay TEMPLATE. Copy to site-init.sh (next to init-server.sh, or point
# at it with SITE_INIT=<url-or-path>) and edit for your server.
#
# init-server.sh runs this after the base system is configured, exporting:
#   SERVER_ROLE   "int" or "prod"
#   ALERT_EMAIL   address for system + uptime alerts (empty on int)
#   PUBLIC_IP     public IPv4
#   TAILSCALE_IP  Tailscale IPv4
#   NEW_USER      the non-root user being created
#
# Put anything host- or owner-specific here (URL monitoring, app config, deploy
# reminders) so init-server.sh itself stays generic and reusable.
set -euo pipefail

SERVER_ROLE="${SERVER_ROLE:-int}"

# Example: email an alert if any URL stops returning HTTP 200 (prod only; the
# `mail`/msmtp relay is configured by init-server.sh on prod servers).
if [[ "$SERVER_ROLE" == "prod" ]]; then
  : "${ALERT_EMAIL:?prod overlay needs ALERT_EMAIL from init-server.sh}"
  UPTIME_URLS="https://example.com https://app.example.com"

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
fi
