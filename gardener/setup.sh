#!/usr/bin/env bash
# Provision gardener, a Raspberry Pi 4 running the rpi-gardener containers.
# The app is deployed separately, this only adds what Home Assistant reads.
# Idempotent. Run as a sudoer, from any directory: ./gardener/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

main() {
  # python3-docker adds container stats to what glances exposes
  install_glances "${GARDENER_IP}" python3-docker
  log "done, add the Glances integration in HA with host ${GARDENER_IP}"
}

main "$@"
