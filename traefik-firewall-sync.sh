#!/usr/bin/env bash
# Keeps the firewall pointing at Traefik.
#
# The servers run ufw with ufw-docker, so a published container port is only reachable from
# outside if a `ufw route allow` rule names the container's internal address. Those addresses are
# not stable: whenever the dokploy-traefik container is recreated (a Dokploy update, a change to
# Traefik's environment or ports in the panel) it can come back with another one, and every public
# site on the server then times out while still answering over the tailnet.
#
# `ufw-docker allow dokploy-traefik 80` is not enough to repair that, because it only knows the
# networks `docker inspect` lists. A container attached to an overlay network alone has its
# published ports forwarded through docker_gwbridge, which is not among them. So this asks the one
# place that cannot be wrong, Docker's own DNAT rules, where ports 80 and 443 are sent, and makes
# the firewall agree.
#
#   traefik-firewall-sync            make it so
#   traefik-firewall-sync --check    say what would change, change nothing; exit 1 if anything would
#   traefik-firewall-sync --install  install this script and a timer that runs it every minute
#
# init-server.sh installs it on new servers. On one that already exists:
#   curl -fsSL https://raw.githubusercontent.com/denniskasper/denniskasper.dev/main/traefik-firewall-sync.sh \
#     -o /tmp/traefik-firewall-sync.sh && sudo bash /tmp/traefik-firewall-sync.sh --install
#
# Idempotent. It only ever removes rules it added itself, recognised by their comment.
set -euo pipefail

PORTS=(80 443)
TAG="traefik-firewall-sync"
INSTALLED="/usr/local/sbin/traefik-firewall-sync"
check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 2; }

if [[ "${1:-}" == "--install" ]]; then
  install -m 0755 "${BASH_SOURCE[0]}" "$INSTALLED"
  cat > /etc/systemd/system/traefik-firewall-sync.service <<UNIT
[Unit]
Description=Point the firewall at the Traefik container's current address
After=docker.service ufw.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$INSTALLED
UNIT
  cat > /etc/systemd/system/traefik-firewall-sync.timer <<'UNIT'
[Unit]
Description=Re-check the Traefik firewall rules every minute

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now traefik-firewall-sync.timer
  echo "installed; the timer runs it every minute"
  # Traefik may not be up yet on a server that is still being set up; the timer will catch it.
  "$INSTALLED" || true
  exit 0
fi

changes=0
wanted=()

for port in "${PORTS[@]}"; do
  # -A DOCKER ! -i docker_gwbridge -p tcp -m tcp --dport 443 -j DNAT --to-destination 172.18.0.9:443
  while read -r target; do
    [[ -n "$target" ]] && wanted+=("${target%:*} $port")
  done < <(iptables -t nat -S DOCKER 2>/dev/null \
            | grep -E -- "-p tcp .*--dport $port -j DNAT" \
            | grep -oE -- '--to-destination [0-9.]+:[0-9]+' | awk '{print $2}' | sort -u)
done

if [[ ${#wanted[@]} -eq 0 ]]; then
  echo "Docker forwards neither 80 nor 443 anywhere: is dokploy-traefik running?" >&2
  exit 3
fi

status=$(ufw status)

for pair in "${wanted[@]}"; do
  read -r address port <<<"$pair"
  # Any rule that lets the port through to that address will do, ours or ufw-docker's.
  if grep -qE "^${address//./\\.} ${port}/tcp +ALLOW FWD +Anywhere" <<<"$status"; then
    continue
  fi
  changes=1
  if $check_only; then
    echo "would allow  $address $port/tcp"
  else
    ufw route allow proto tcp from any to "$address" port "$port" comment "$TAG" >/dev/null
    echo "allowed      $address $port/tcp"
  fi
done

# Rules of ours that point where Docker no longer forwards are left over from an earlier address.
while read -r address port; do
  [[ -z "$address" ]] && continue
  printf '%s\n' "${wanted[@]}" | grep -qxF "$address $port" && continue
  changes=1
  if $check_only; then
    echo "would remove $address $port/tcp (stale)"
  else
    ufw route delete allow proto tcp from any to "$address" port "$port" >/dev/null
    echo "removed      $address $port/tcp (stale)"
  fi
done < <(grep -E "ALLOW FWD .*# ${TAG}\$" <<<"$status" | awk '{split($2,p,"/"); print $1, p[1]}')

if (( changes == 0 )); then
  echo "in step: $(printf '%s/tcp ' "${wanted[@]// /:}")"
fi
$check_only && exit "$changes"
exit 0
