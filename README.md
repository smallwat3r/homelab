# homelab

Config and provisioning for the Raspberry Pis on the home network, managed
from this machine over the tailnet. One directory per host, `lib.sh` holds
helpers shared by the setup scripts, `config` the shared facts (domain, LAN
IPs, paths).

| Directory | Host     | Role |
|-----------|----------|------|
| ha        | ha       | Tailscale subnet router and exit node, Home Assistant Container, TLS certificate |
| nas       | nas      | OpenMediaVault, Glances for HA |
| gardener  | gardener | rpi-gardener containers, Glances for HA |

Hosts are reached as `pi@<host>.ts.smallwat3r.com`, public A records that
point at the tailnet IPs, so they only answer from inside the tailnet.
Tailscale has a split DNS route sending that domain to Cloudflare's
resolvers, set in the admin console.

## Usage

```
make provision        # provision every host, idempotent
make provision-<dir>  # rsync the repo to the host and run its setup.sh, idempotent
make deploy-gardener  # deploy smallwat3r/rpi-gardener to the gardener Pi
make ha-sync          # push Home Assistant config, validate, restart
make ha-check         # validate the Home Assistant config
make ha-restart       # restart the Home Assistant container
make ha-logs          # tail the Home Assistant container logs
make status           # quick health check of all hosts
make dns              # point <host>.ts.smallwat3r.com at each tailnet IP, DRY_RUN=1 to preview
make cert-token       # put the Cloudflare token on ha for certbot, once
```

## Secrets

One Cloudflare API token with Zone:DNS:Edit on smallwat3r.com, stored in
pass as `cloudflare/ts-dns`. `make dns` reads it locally, `make cert-token`
copies it to ha as `/root/.secrets/cloudflare.ini` for certbot. No other
host holds it.

## Home Assistant

https://ha.ts.smallwat3r.com, HTTPS only on 443. ha holds a Let's
Encrypt wildcard for `*.ts.smallwat3r.com`, issued by certbot through the
Cloudflare DNS-01 challenge and renewed by certbot's timer, the deploy hook
restarts HA.

Runtime state stays on the Pi under /opt/homeassistant, only compose.yaml,
configuration.yaml and the dashboards are repo-managed. HACS and the eero
integration are installed straight into custom_components by setup.sh, so
HACS does not manage eero updates.

One-time steps in the HA UI that setup.sh cannot do:

- Settings > System > Network: port 443, SSL certificate and key
  `/etc/letsencrypt/live/ts.smallwat3r.com/fullchain.pem` and `privkey.pem`.
  HTTP settings are store-managed in current HA, yaml http blocks are
  ignored.
- Add integrations: HACS, eero (plain eero login, not Amazon, then in
  Configure set both client filters to Exclude with empty lists to track
  every client), Glances for nas and gardener (host from `config`, port
  61208, no auth).

The Network dashboard (`ha/homeassistant/dashboards/network.yaml`) lists
eero devices with pause switches, speed test, and NAS and gardener health
from Glances.

## Glances

nas and gardener run Glances as a read-only HTTP API on port 61208, bound
to the LAN address so it is not reachable on the tailnet IP. glances.conf
hides filesystems, disks and interfaces that would only add noise in HA.
Entities HA already created for hidden items stay in its registry as
unavailable until deleted from the Glances entities list.
