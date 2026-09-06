#!/usr/bin/env bash
# Upsert A records <host>.ts.smallwat3r.com -> tailnet IP in Cloudflare for
# the hosts below, taking the IPs from the local tailscale client.
# Token: a Cloudflare API token with Zone:DNS:Edit on smallwat3r.com, read
# from $CF_API_TOKEN or pass, entry named by CF_PASS_ENTRY in config.
# DRY_RUN=1 prints the changes without applying them.

set -euo pipefail

# shellcheck source=config
source "$(dirname "${BASH_SOURCE[0]}")/../config"
readonly ZONE="${DOMAIN#*.}"
readonly HOSTS=(ha nas gardener)
readonly API="https://api.cloudflare.com/client/v4"

token="${CF_API_TOKEN:-$(pass show "${CF_PASS_ENTRY}" 2>/dev/null || true)}"
if [[ -z "${token}" ]]; then
  echo "no Cloudflare token, set CF_API_TOKEN or 'pass insert ${CF_PASS_ENTRY}'" >&2
  exit 1
fi
readonly token

# On failure the response body goes to stderr, Cloudflare puts the reason there
cf() {
  local method="$1" path="$2" out
  shift 2
  # header read from a file descriptor so the token stays off curl's argv
  out="$(curl -sS --fail-with-body -X "${method}" "${API}${path}" \
    -H @<(printf 'Authorization: Bearer %s\n' "${token}") \
    -H "Content-Type: application/json" "$@")" || { printf '%s\n' "${out}" >&2; return 1; }
  printf '%s\n' "${out}"
}

# Skips the API call in dry-run mode, silences the response otherwise
apply() { [[ "${DRY_RUN:-}" ]] || "$@" >/dev/null; }

tailnet="$(tailscale status --json)"
readonly tailnet

tailnet_ip() {
  jq -r --arg h "$1" '
    [.Self] + [(.Peer // {})[]] | .[] | select(.HostName == $h) | .TailscaleIPs[0]' <<<"${tailnet}"
}

zone_id="$(cf GET "/zones?name=${ZONE}" | jq -r '.result[0].id')"
if [[ -z "${zone_id}" || "${zone_id}" == "null" ]]; then
  echo "zone ${ZONE} not found in Cloudflare" >&2
  exit 1
fi
readonly zone_id

for host in "${HOSTS[@]}"; do
  name="${host}.${DOMAIN}"
  ip="$(tailnet_ip "${host}")"
  if [[ -z "${ip}" ]]; then
    echo "${name}: ${host} is not on the tailnet, skipped" >&2
    continue
  fi
  record="$(cf GET "/zones/${zone_id}/dns_records?type=A&name=${name}" | jq -c '.result[0]')"
  old_ip="$(jq -r '.content' <<<"${record}")"
  body="$(jq -nc --arg n "${name}" --arg ip "${ip}" \
    '{type:"A", name:$n, content:$ip, ttl:300, proxied:false}')"
  if [[ "${record}" == "null" ]]; then
    echo "${name} -> ${ip} (create)"
    apply cf POST "/zones/${zone_id}/dns_records" --data "${body}"
  elif [[ "${old_ip}" != "${ip}" ]]; then
    echo "${name} -> ${ip} (was ${old_ip})"
    apply cf PUT "/zones/${zone_id}/dns_records/$(jq -r '.id' <<<"${record}")" --data "${body}"
  else
    echo "${name} -> ${ip} (unchanged)"
  fi
done
