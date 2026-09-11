#!/usr/bin/env bash
# Health of lookout for make status. No -e, a down unit must not hide the rest.
set -uo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

tailscale status --self | head -1
units watchdog.timer nginx certbot.timer
# the page as text, one line per service and the checked time
curl -sf -m 5 "https://lookout.${DOMAIN}/" | grep -E '^<tr><td|^<p>' | sed 's/<[^>]*>/ /g'
