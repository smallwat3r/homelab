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

stuff_share_uuid() {
  sudo omv-rpc -u admin ShareMgmt enumerateSharedFolders \
    | python3 -c 'import json,sys; print(next(s["uuid"] for s in json.load(sys.stdin) if s["name"] == "stuff"))'
}

# Absolute path of the stuff share on disk, OMV returns it JSON-quoted
stuff_share_path() {
  sudo omv-rpc -u admin ShareMgmt getPath "{\"uuid\":\"$(stuff_share_uuid)\"}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).rstrip("/"))'
}

# OMV's File Browser plugin, a web file manager over the stuff share so it
# can be browsed from a Home Assistant link. Settings go through OMV's RPC
# like the UI does, so the web UI shows nothing pending afterwards.
install_filebrowser() {
  log "file browser"
  if ! dpkg -s openmediavault-filebrowser >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openmediavault-filebrowser
  fi
  sudo omv-rpc -u admin FileBrowser set \
    "{\"enable\":true,\"port\":${FILEBROWSER_PORT},\"sslcertificateref\":\"\",\"sharedfolderref\":\"$(stuff_share_uuid)\"}" >/dev/null
  sudo omv-rpc -u admin Config applyChanges '{"modules":["filebrowser"],"force":false}' >/dev/null

  log "verify file browser"
  retry 10 curl -sf -m 3 -o /dev/null "http://127.0.0.1:${FILEBROWSER_PORT}/" \
    || { echo "file browser not answering on port ${FILEBROWSER_PORT}" >&2; return 1; }
}

# Put File Browser behind OMV's nginx at /files, the bare port is still
# open but the short URL is what HA links to
install_filebrowser_path() {
  log "file browser /files"
  sudo install -D -m 0644 "${HOST_DIR}/filebrowser-baseurl.conf" \
    /etc/systemd/system/container-filebrowser-app.service.d/baseurl.conf
  sudo systemctl daemon-reload
  sudo systemctl restart container-filebrowser-app.service
  sed "s/@PORT@/${FILEBROWSER_PORT}/" "${HOST_DIR}/filebrowser-nginx.conf" \
    | sudo tee /etc/nginx/openmediavault-webgui.d/filebrowser.conf >/dev/null
  sudo nginx -t -q
  sudo systemctl reload nginx

  log "verify file browser /files"
  retry 10 bash -c 'curl -sf -m 3 http://127.0.0.1/files/ | grep -q /files/public/static' \
    || { echo "file browser not answering on /files" >&2; return 1; }
}

# Forgejo as a podman quadlet with its data on the NAS disk. The owner and
# their API token are created once through the CLI, the password is random
# and printed here, the web installer is locked out by the quadlet's config.
install_forgejo() {
  local dir="$1"
  log "forgejo"
  sudo install -d "${dir}"
  sed "s|@DIR@|${dir}|g; s|@PORT@|${FORGEJO_PORT}|g; s|@DOMAIN@|${DOMAIN}|g" "${HOST_DIR}/forgejo.container" \
    | sudo tee /etc/containers/systemd/forgejo.container >/dev/null
  sudo systemctl daemon-reload
  # restart rather than start so quadlet changes always take effect
  sudo systemctl restart forgejo.service

  log "verify forgejo"
  retry 30 curl -sf -m 3 -o /dev/null "http://127.0.0.1:${FORGEJO_PORT}/api/v1/version" \
    || { echo "forgejo not answering on port ${FORGEJO_PORT}" >&2; return 1; }
  if ! sudo podman exec -u git forgejo forgejo admin user list | grep -qw "${FORGEJO_USER}"; then
    log "forgejo user ${FORGEJO_USER}, change the password below on first login"
    sudo podman exec -u git forgejo forgejo admin user create --admin --random-password \
      --must-change-password --username "${FORGEJO_USER}" --email "${FORGEJO_USER}@nas.${DOMAIN}"
  fi
  if ! sudo test -f "${FORGEJO_TOKEN}"; then
    log "forgejo api token"
    sudo podman exec -u git forgejo forgejo admin user generate-access-token --raw \
      --username "${FORGEJO_USER}" --token-name mirror --scopes write:repository,read:user \
      | sudo sh -c "umask 077 && cat > ${FORGEJO_TOKEN}"
  fi
}

# Put Forgejo behind OMV's nginx at /git, the bare port only listens on
# localhost
install_forgejo_path() {
  log "forgejo /git"
  sed "s/@PORT@/${FORGEJO_PORT}/" "${HOST_DIR}/forgejo-nginx.conf" \
    | sudo tee /etc/nginx/openmediavault-webgui.d/forgejo.conf >/dev/null
  sudo nginx -t -q
  sudo systemctl reload nginx

  log "verify forgejo /git"
  retry 10 curl -sf -m 3 -o /dev/null "http://127.0.0.1/git/api/v1/version" \
    || { echo "forgejo not answering on /git" >&2; return 1; }
}

# Mirror every GitHub repo into Forgejo, daily from cron for new repos and
# once now. Needs the GitHub token from `make github-token`, skips without it.
install_forgejo_mirror() {
  log "forgejo mirror"
  sed "s|@PORT@|${FORGEJO_PORT}|g; s|@USER@|${FORGEJO_USER}|g; s|@GH_CREDENTIALS@|${GH_CREDENTIALS}|g; s|@FORGEJO_TOKEN@|${FORGEJO_TOKEN}|g" \
    "${HOST_DIR}/forgejo-mirror.py" | sudo install -m 0755 /dev/stdin /usr/local/sbin/forgejo-mirror
  sudo ln -sf /usr/local/sbin/forgejo-mirror /etc/cron.daily/forgejo-mirror
  sudo forgejo-mirror
}

# The wildcard is loaded into OMV's certificate store by omv-cert, which is
# also certbot's deploy hook so renewals land in the web UI on their own
install_omv_certificate() {
  sed "s/@DOMAIN@/${DOMAIN}/g" "${HOST_DIR}/omv-cert.py" \
    | sudo install -m 0755 /dev/stdin /usr/local/sbin/omv-cert
  install_certificate /usr/local/sbin/omv-cert
  # certbot only runs the hook when it issues, cover the already-valid case
  sudo /usr/local/sbin/omv-cert
}

main() {
  install_tailscale
  install_omv
  install_omv_certificate
  install_glances "${NAS_IP}"
  install_filebrowser
  install_filebrowser_path
  # on the disk next to the share, not in it, so it is not browsable or writable from File Browser
  install_forgejo "$(dirname "$(stuff_share_path)")/forgejo"
  install_forgejo_path
  install_forgejo_mirror
  # into the share, so sent files show up in File Browser and HA's /media/NAS
  install_taildrop "$(stuff_share_path)/taildrop"
  log "done, https://nas.${DOMAIN}"
}

main "$@"
