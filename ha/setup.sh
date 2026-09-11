#!/usr/bin/env bash
# Provision ha, the Raspberry Pi 4 acting as Tailscale subnet router and
# exit node (going out through IVPN), and running Home Assistant Container.
# Idempotent. Run as the pi user, from any directory: ./ha/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

# apt packages beyond what lib's shared installers bring, in one go
readonly PACKAGES=(unzip ethtool wireguard-tools jq)
readonly HACS_DIR="${HA_CONFIG_DIR}/custom_components/hacs"
readonly HACS_ZIP_URL="https://github.com/hacs/integration/releases/latest/download/hacs.zip"
readonly EERO_DIR="${HA_CONFIG_DIR}/custom_components/eero"
readonly EERO_TAR_URL="https://github.com/schmittx/home-assistant-eero/archive/refs/heads/main.tar.gz"

require_pi_user() {
  if [[ "$(id -un)" != "pi" ]]; then
    echo "run as the pi user" >&2
    exit 1
  fi
}

install_deps() {
  log "deps"
  apt_install "${PACKAGES[@]}"
}

# On top of lib's subnet router: GRO tuning, tailscaled after docker, and
# the exit node
setup_subnet_router() {
  advertise_lan_subnet --advertise-exit-node
  sudo install -m 0644 "${HOST_DIR}/tailscale-gro.service" /etc/systemd/system/
  sudo install -D -m 0644 "${HOST_DIR}/tailscaled-after-docker.conf" \
    /etc/systemd/system/tailscaled.service.d/after-docker.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now tailscale-gro.service
}

# Devices that pick ha as exit node go out through an IVPN WireGuard
# tunnel, so they need no IVPN client of their own and IVPN sees one device.
# Plain wg-quick rather than the IVPN daemon, whose kill switch drops
# everything in FORWARD that is not the tunnel, killing the subnet router.
# The routing lives in the wg-quick drop-in, the config comes from
# `make ivpn-conf`. Loose reverse path filtering, replies arriving on the
# tunnel would otherwise fail the strict check against the main table.
setup_ivpn_exit() {
  log "ivpn"
  if ! sudo test -f "${IVPN_CONF}"; then
    echo "missing ${IVPN_CONF}, run 'make ivpn-conf' first" >&2
    exit 1
  fi
  echo "net.ipv4.conf.all.rp_filter = 2" | sudo tee /etc/sysctl.d/99-ivpn.conf >/dev/null
  sudo sysctl -q --system
  sed "s|@LAN_SUBNET@|${LAN_SUBNET}|g" "${HOST_DIR}/wg-quick-ivpn.conf" \
    | sudo install -D -m 0644 /dev/stdin /etc/systemd/system/wg-quick@ivpn.service.d/routing.conf
  sudo systemctl daemon-reload
  sudo systemctl enable wg-quick@ivpn.service
  # restart rather than enable --now so config and drop-in changes take effect
  sudo systemctl restart wg-quick@ivpn.service

  log "verify ivpn"
  # a packet arriving on tailscale0 for the internet must leave via the tunnel
  if ! sudo ip route get 1.1.1.1 from 100.64.0.1 iif tailscale0 | grep -q ' dev ivpn '; then
    echo "exit node traffic is not routed into the ivpn tunnel" >&2
    return 1
  fi
}

# The NAS share is mounted on the host and bound into the HA container as
# /media/NAS, HA Container has no network storage of its own
mount_nas_share() {
  log "nas share"
  sudo install -d /mnt/nas/stuff
  sed "s/@NAS_IP@/${NAS_IP}/" "${HOST_DIR}/mnt-nas-stuff.mount" \
    | sudo tee /etc/systemd/system/mnt-nas-stuff.mount >/dev/null
  sudo install -m 0644 "${HOST_DIR}/mnt-nas-stuff.automount" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now mnt-nas-stuff.automount
  # touching the path triggers the mount, a down NAS is not fatal here
  timeout 10 ls /mnt/nas/stuff >/dev/null 2>&1 || echo "nas share not mounted yet, it mounts on first access" >&2
}

install_docker() {
  log "docker"
  if ! command -v docker >/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi
  if ! id -nG | grep -qw docker; then
    sudo usermod -aG docker "${USER}"
    echo "log out and back in for docker group membership, then rerun" >&2
    exit 1
  fi
}

install_hacs() {
  if [[ -f "${HACS_DIR}/manifest.json" ]]; then
    return
  fi
  log "hacs"
  local zip
  zip="$(mktemp)"
  curl -fsSL -o "${zip}" "${HACS_ZIP_URL}"
  mkdir -p "${HACS_DIR}"
  unzip -qo "${zip}" -d "${HACS_DIR}"
  rm -f "${zip}"
}

# eero has no release zip, and HACS custom repositories need the UI anyway
install_eero() {
  if [[ -f "${EERO_DIR}/manifest.json" ]]; then
    return
  fi
  log "eero"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/eero.tar.gz" "${EERO_TAR_URL}"
  tar -xzf "${tmp}/eero.tar.gz" -C "${tmp}" --strip-components=2 "home-assistant-eero-main/custom_components/eero"
  mv "${tmp}/eero" "${EERO_DIR}"
  rm -rf "${tmp}"
}

# The IVPN switch in HA: the container runs ssh against its own host with a
# key whose forced command is ivpn-ctl, so it can start, stop and read the
# tunnel and nothing else. Key and known_hosts live in the config dir,
# which the container sees as /config, the ssh config comes from the repo.
install_ivpn_switch() {
  log "ivpn switch"
  sudo install -m 0755 "${HOST_DIR}/ivpn-ctl" /usr/local/bin/
  local ssh_dir="${HA_CONFIG_DIR}/.ssh"
  [[ -f "${ssh_dir}/ivpn" ]] || ssh-keygen -q -t ed25519 -N "" -C "homeassistant ivpn switch" -f "${ssh_dir}/ivpn"
  echo "127.0.0.1 $(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)" > "${ssh_dir}/known_hosts"
  local entry
  entry="restrict,command=\"/usr/local/bin/ivpn-ctl\" $(cat "${ssh_dir}/ivpn.pub")"
  install -d -m 0700 "${HOME}/.ssh"
  grep -qxF "${entry}" "${HOME}/.ssh/authorized_keys" 2>/dev/null \
    || echo "${entry}" >> "${HOME}/.ssh/authorized_keys"
  chmod 0600 "${HOME}/.ssh/authorized_keys"
}

# HA serves TLS itself on 443 with the wildcard cert, mounted read-only by
# the compose file. HTTP settings are store-managed in current HA (yaml http
# blocks are ignored after first boot), so this is a one-time UI step:
# Settings > System > Network, port 443, SSL certificate and key
#   /etc/letsencrypt/live/<DOMAIN>/fullchain.pem and privkey.pem
install_home_assistant() {
  log "home assistant"
  sudo install -d -o "${USER}" -g "${USER}" "${HA_DIR}" "${HA_CONFIG_DIR}"
  install -m 0644 "${HOST_DIR}/homeassistant/compose.yaml" "${HA_DIR}/"
  # configuration.yaml is repo-managed, HA writes UI edits to the included
  # automations/scripts/scenes files, never here
  install -m 0644 "${HOST_DIR}/homeassistant/configuration.yaml" "${HA_CONFIG_DIR}/"
  # the HA container (root) may own these after UI edits, do not touch them
  local f
  for f in automations scripts scenes; do
    [[ -f "${HA_CONFIG_DIR}/${f}.yaml" ]] || touch "${HA_CONFIG_DIR}/${f}.yaml"
  done
  cp -r "${HOST_DIR}"/homeassistant/{dashboards,themes,www,.ssh} "${HA_CONFIG_DIR}/"
  install -D -m 0644 "${HOST_DIR}/../ocrab.woff2" "${HA_CONFIG_DIR}/www/fonts/ocrab.woff2"
  install_ivpn_switch
  install_hacs
  install_eero
  docker compose --project-directory "${HA_DIR}" up -d
}

# Docker sets the FORWARD policy to DROP, subnet routing only survives if
# tailscale's jump stays ahead of DOCKER-USER in the chain
verify_forwarding() {
  log "verify forwarding"
  if [[ "$(sudo iptables -S FORWARD | sed -n 2p)" != "-A FORWARD -j ts-forward" ]]; then
    sudo systemctl restart tailscaled
  fi
  retry 10 bash -c 'sudo iptables -S FORWARD | sed -n 2p | grep -q ts-forward' \
    || { echo "ts-forward is not ahead of DOCKER-USER in the FORWARD chain" >&2; return 1; }
}

main() {
  require_pi_user
  install_deps
  keep_journal_in_ram
  setup_subnet_router
  setup_ivpn_exit
  install_taildrop "${HOME}/taildrop"
  install_docker
  docker_logs_to_journal
  mount_nas_share
  # the hook restarts HA so it serves the renewed files
  install_certificate "docker restart homeassistant 2>/dev/null || true"
  install_home_assistant
  verify_forwarding
  log "done, https://ha.${DOMAIN}"
}

main "$@"
