# Shared helpers, sourced by each host's setup.sh, which must set HOST_DIR
# to its own directory first.

source "$(dirname "${BASH_SOURCE[0]}")/hosts.conf"

log() { printf '==> %s\n' "$*"; }

# Every host joins the tailnet directly, even though capo's subnet routing
# already reaches them, so remote access survives capo being down
install_tailscale() {
  log "tailscale"
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  # tailscale up is not idempotent (it resets prefs it is not given), only
  # run it to authenticate
  if ! sudo tailscale status >/dev/null 2>&1; then
    sudo tailscale up
  fi
}

# Install glances from HOST_DIR's glances.conf and glances.service, then wait
# for its API to answer on the given LAN address. Extra apt packages can be
# passed after the address.
install_glances() {
  local ip="$1"
  shift
  log "glances"
  if ! command -v glances >/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      glances python3-fastapi python3-uvicorn python3-jinja2 "$@"
  fi
  # the unit reads BIND from here, keeping the address out of the unit file
  echo "BIND=${ip}" | sudo tee /etc/default/glances >/dev/null
  sudo install -m 0644 "${HOST_DIR}/glances.service" /etc/systemd/system/
  sudo install -D -m 0644 "${HOST_DIR}/glances.conf" /etc/glances/glances.conf
  sudo systemctl daemon-reload
  sudo systemctl enable glances.service
  # restart rather than enable --now so config changes always take effect
  sudo systemctl restart glances.service

  log "verify glances"
  for _ in {1..10}; do
    curl -sf -m 3 "http://${ip}:61208/api/4/status" >/dev/null && return
    sleep 2
  done
  echo "glances api not answering on ${ip}:61208" >&2
  return 1
}
