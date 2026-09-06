#!/usr/bin/env bash
# Provision ha, the Raspberry Pi 4 acting as Tailscale subnet router and
# exit node, and running Home Assistant Container.
# Idempotent. Run as the pi user, from any directory: ./ha/setup.sh

set -euo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

readonly LAN_SUBNET="192.168.4.0/24"
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
  local cmd
  for cmd in unzip ethtool; do
    command -v "${cmd}" >/dev/null || sudo apt-get install -y "${cmd}"
  done
}

# On top of lib's install: forwarding sysctls, GRO tuning, and advertising
# the LAN subnet and exit node
setup_subnet_router() {
  install_tailscale
  log "subnet router"
  sudo install -m 0644 "${HOST_DIR}/tailscale/99-tailscale.conf" /etc/sysctl.d/
  sudo sysctl -q --system
  sudo install -m 0644 "${HOST_DIR}/tailscale/tailscale-gro.service" /etc/systemd/system/
  sudo install -D -m 0644 "${HOST_DIR}/tailscale/tailscaled-after-docker.conf" \
    /etc/systemd/system/tailscaled.service.d/after-docker.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now tailscale-gro.service
  sudo tailscale set --advertise-routes="${LAN_SUBNET}" --advertise-exit-node
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
  cp -r "${HOST_DIR}"/homeassistant/{dashboards,themes,www} "${HA_CONFIG_DIR}/"
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

  for _ in {1..10}; do
    if sudo iptables -S FORWARD | sed -n 2p | grep -q ts-forward; then
      return
    fi
    sleep 1
  done
  echo "ts-forward is not ahead of DOCKER-USER in the FORWARD chain" >&2
  return 1
}

main() {
  require_pi_user
  install_deps
  setup_subnet_router
  install_taildrop "${HOME}/taildrop"
  install_docker
  mount_nas_share
  # the hook restarts HA so it serves the renewed files
  install_certificate "docker restart homeassistant 2>/dev/null || true"
  install_home_assistant
  verify_forwarding
  log "done, https://ha.${DOMAIN}"
}

main "$@"
