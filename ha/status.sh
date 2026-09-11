#!/usr/bin/env bash
# Health of ha for make status. No -e, a down unit must not hide the rest.
set -uo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

docker ps --format "table {{.Names}}\t{{.Status}}"
tailscale status --self | head -1
units taildrop wg-quick@ivpn certbot.timer
# 0 until a device sends traffic through the exit node, WireGuard only
# handshakes on demand
last=$(sudo wg show ivpn latest-handshakes | cut -f2)
if [[ "${last}" == 0 ]]; then
  echo "ivpn handshake   none yet, no exit node traffic since the tunnel came up"
else
  echo "ivpn handshake   $(( $(date +%s) - last ))s ago"
fi
sudo iptables -S FORWARD | sed -n 2p
findmnt -t cifs -no SOURCE,FSTYPE /mnt/nas/stuff || echo "nas share not mounted"
