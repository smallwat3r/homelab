#!/usr/bin/env bash
# Provision lookout, the Raspberry Pi 3A+ that advertises the LAN subnet as
# a second Tailscale subnet router, so the tailnet fails over to it while ha
# is down, and runs a watchdog that posts to Slack when a host or one of
# nas's services stops answering, with a status page served by nginx.
# Wi-Fi only and 512MB, nothing else runs here.
# Idempotent. Run as a sudoer, from any directory: ./lookout/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

install_watchdog() {
  log "watchdog"
  if ! sudo test -f "${SLACK_CONF}"; then
    echo "missing ${SLACK_CONF}, run 'make slack-webhook' first" >&2
    exit 1
  fi
  sed "s/@DOMAIN@/${DOMAIN}/g" "${HOST_DIR}/watchdog.py" \
    | sudo install -m 0755 /dev/stdin /usr/local/bin/watchdog
  sudo install -m 0644 "${HOST_DIR}/watchdog.service" "${HOST_DIR}/watchdog.timer" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now watchdog.timer
  # one run now, so a bad webhook or a host already down shows up here
  sudo systemctl start watchdog.service
}

# The page the watchdog renders, over HTTPS on the tailnet, in the shared
# ocrab font, served from the same directory
install_page() {
  log "page"
  sudo install -m 0644 -o www-data -g www-data "${HOST_DIR}/../ocrab.woff2" /var/lib/watchdog/
  if ! command -v nginx >/dev/null; then
    apt_install nginx-light
  fi
  sed "s/@DOMAIN@/${DOMAIN}/g" "${HOST_DIR}/nginx.conf" | sudo tee /etc/nginx/conf.d/lookout.conf >/dev/null
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t -q
  sudo systemctl restart nginx

  log "verify page"
  retry 5 bash -c "curl -sf -m 5 --resolve lookout.${DOMAIN}:443:127.0.0.1 https://lookout.${DOMAIN}/ | grep -q '<h1>lookout'" \
    || { echo "https://lookout.${DOMAIN} is not serving the page" >&2; return 1; }
}

main() {
  advertise_lan_subnet
  keep_journal_in_ram
  # the hook only runs on issuance, which can happen before nginx is installed
  install_certificate "systemctl reload nginx 2>/dev/null || true"
  install_watchdog
  install_page
  log "done, https://lookout.${DOMAIN}, approve lookout's subnet route in the Tailscale admin console"
}

main "$@"
