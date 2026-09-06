# Shared helpers, sourced by each host's setup.sh, which must set HOST_DIR
# to its own directory first.

source "$(dirname "${BASH_SOURCE[0]}")/config"

log() { printf '==> %s\n' "$*"; }

# Every host joins the tailnet directly, even though ha's subnet routing
# already reaches them, so remote access survives ha being down
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
  # lets this user run tailscale commands (file cp, file get) without sudo
  sudo tailscale set --operator="${USER}"
}

# Receive Taildrop files into the given directory, created if missing and
# owned by this user, who the unit runs as. Any device on the tailnet can
# then send with `tailscale file cp <file> <host>:` or the share sheet.
install_taildrop() {
  local dir="$1"
  log "taildrop"
  # mkdir as the user rather than install -d, so a setgid parent (the NAS
  # share) keeps its group on the new directory
  sudo -u "${USER}" mkdir -p "${dir}"
  sed "s|@DIR@|${dir}|g; s|@USER@|${USER}|g" "${HOST_DIR}/../taildrop.service" \
    | sudo tee /etc/systemd/system/taildrop.service >/dev/null
  sudo systemctl daemon-reload
  sudo systemctl enable taildrop.service
  sudo systemctl restart taildrop.service
}

# One wildcard Let's Encrypt certificate for *.DOMAIN via the DNS-01
# challenge, Cloudflare edits the TXT record so nothing needs to be reachable
# from the internet. Needs the zone token from `make cert-token-<host>`.
# certbot's own systemd timer renews, the deploy hook given here tells the
# host's service to pick up the new files.
install_certificate() {
  local hook="$1"
  log "certificate"
  if ! sudo test -f "${CF_CREDENTIALS}"; then
    echo "missing ${CF_CREDENTIALS}, run 'make cert-token-$(basename "${HOST_DIR}")' first" >&2
    exit 1
  fi
  if ! command -v certbot >/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      certbot python3-certbot-dns-cloudflare
  fi
  sudo certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --keep-until-expiring --cert-name "${DOMAIN}" -d "*.${DOMAIN}" \
    --dns-cloudflare --dns-cloudflare-credentials "${CF_CREDENTIALS}" \
    --dns-cloudflare-propagation-seconds 20 \
    --deploy-hook "${hook}"
}

# Install glances from HOST_DIR's glances.conf and glances.service, then wait
# for its API to answer on the given LAN address. Extra apt packages can be
# passed after the address.
# Deliberately the LAN IP, not <host>.DOMAIN over the tailnet: HA and the
# Pis share a LAN, so polling over Tailscale would add a dependency on
# tailscaled for local monitoring and encrypt traffic that never leaves the
# house. The LAN-only bind also keeps the unauthenticated API off the
# tailnet address. Revisit if a polled host ever sits on another network.
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
    curl -sf -m 3 "http://${ip}:${GLANCES_PORT}/api/4/status" >/dev/null && return
    sleep 2
  done
  echo "glances api not answering on ${ip}:${GLANCES_PORT}" >&2
  return 1
}
