#!/usr/bin/env bash
# Health of nas for make status. No -e, a down unit must not hide the rest.
set -uo pipefail

HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HOST_DIR

source "${HOST_DIR}/../lib.sh"

units glances pod-filebrowser forgejo taildrop certbot.timer
curl -s -m 3 "http://${NAS_IP}:${GLANCES_PORT}/api/4/status"; echo
