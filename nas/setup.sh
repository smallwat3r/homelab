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

# OMV's File Browser plugin, a web file manager over the stuff share so it
# can be browsed from a Home Assistant link. Settings go through OMV's RPC
# like the UI does, so the web UI shows nothing pending afterwards.
install_filebrowser() {
  log "file browser"
  if ! dpkg -s openmediavault-filebrowser >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openmediavault-filebrowser
  fi
  local share
  share="$(sudo omv-rpc -u admin ShareMgmt enumerateSharedFolders \
    | python3 -c 'import json,sys; print(next(s["uuid"] for s in json.load(sys.stdin) if s["name"] == "stuff"))')"
  sudo omv-rpc -u admin FileBrowser set \
    "{\"enable\":true,\"port\":${FILEBROWSER_PORT},\"sslcertificateref\":\"\",\"sharedfolderref\":\"${share}\"}" >/dev/null
  sudo omv-rpc -u admin Config applyChanges '{"modules":["filebrowser"],"force":false}' >/dev/null

  log "verify file browser"
  for _ in {1..10}; do
    curl -sf -m 3 -o /dev/null "http://127.0.0.1:${FILEBROWSER_PORT}/" && return
    sleep 2
  done
  echo "file browser not answering on port ${FILEBROWSER_PORT}" >&2
  return 1
}

main() {
  install_tailscale
  install_omv
  install_glances "${NAS_IP}"
  install_filebrowser
  log "done, add the Glances integration in HA with host ${NAS_IP}"
}

main "$@"
