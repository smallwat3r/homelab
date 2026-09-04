#!/usr/bin/env bash
# Provision nas, a Raspberry Pi running OpenMediaVault, plus what Home
# Assistant needs to read it.
# Idempotent. Run as a sudoer, from any directory: ./nas/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

# The official installer is the supported way to get OMV on Raspberry Pi OS,
# it reconfigures networking and may prompt for a reboot on first run
install_omv() {
  if dpkg -s openmediavault >/dev/null 2>&1; then
    return
  fi
  log "openmediavault"
  curl -fsSL https://github.com/OpenMediaVault-Plugin-Developers/installScript/raw/master/install | sudo bash
}

main() {
  install_tailscale
  install_omv
  install_glances "${NAS_IP}"
  log "done, add the Glances integration in HA with host ${NAS_IP}"
}

main "$@"
