#!/usr/bin/env bash
# Provision nas, a Raspberry Pi running OpenMediaVault. OMV itself is
# installed by hand, this only adds what Home Assistant needs to read it.
# Idempotent. Run as a sudoer, from any directory: ./nas/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

main() {
  install_glances "${NAS_IP}"
  log "done, add the Glances integration in HA with host ${NAS_IP}"
}

main "$@"
