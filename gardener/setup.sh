#!/usr/bin/env bash
# Provision gardener, a Raspberry Pi 4 running the rpi-gardener containers.
# The app is deployed with make deploy-gardener first, this adds the
# certificate for its nginx and what Home Assistant reads.
# Idempotent. Run as a sudoer, from any directory: ./gardener/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

# The wildcard goes into the app's certs volume by gardener-cert, which is
# also certbot's deploy hook so renewals land in nginx on their own
install_app_certificate() {
  sed "s/@DOMAIN@/${DOMAIN}/g" "${HOST_DIR}/gardener-cert.sh" \
    | sudo install -m 0755 /dev/stdin /usr/local/sbin/gardener-cert
  install_certificate /usr/local/sbin/gardener-cert
  # certbot only runs the hook when it issues, cover the already-valid case
  sudo /usr/local/sbin/gardener-cert

  log "verify certificate"
  # --resolve sends the real name as SNI to the local nginx, curl then
  # checks the chain against the system CAs, so a self-signed cert fails
  retry 5 curl -sf -m 5 -o /dev/null --resolve "gardener.${DOMAIN}:443:127.0.0.1" \
    "https://gardener.${DOMAIN}/health" \
    || { echo "https://gardener.${DOMAIN} is not serving a trusted certificate" >&2; return 1; }
}

main() {
  install_tailscale
  install_app_certificate
  # python3-docker adds container stats to what glances exposes
  install_glances "${GARDENER_IP}" python3-docker
  log "done, https://gardener.${DOMAIN}, add the Glances integration in HA with host ${GARDENER_IP}"
}

main "$@"
