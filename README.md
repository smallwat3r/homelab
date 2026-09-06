# homelab

Config and provisioning for the Raspberry Pis on the home network, managed
from this machine over the tailnet. One directory per host, `lib.sh` holds
helpers shared by the setup scripts, `config` the shared facts (domain, LAN
IPs, paths).

| Directory | Host     | Role |
|-----------|----------|------|
| ha        | ha       | Tailscale subnet router and exit node, Home Assistant Container, TLS certificate |
| nas       | nas      | OpenMediaVault, File Browser, Glances for HA |
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
- Add integrations: HACS, eero, Glances for nas and gardener, System Monitor
  for ha itself.

The Network dashboard (`ha/homeassistant/dashboards/network.yaml`) lists
eero devices with pause switches, speed test, and NAS and gardener health
from Glances, and ha's own from System Monitor.

## NAS share in HA

ha mounts the OMV `stuff` share over SMB at /mnt/nas/stuff (systemd
automount, so a NAS that is down at boot only delays it) and binds it into
the container as /media/NAS, where the Media browser and camera snapshot
actions can use it. The share allows guest access, so no credentials are
stored on ha.

HA's Media browser only lists images, audio and video, so for a real file
manager the NAS runs OMV's File Browser plugin over the same share at
http://nas.ts.smallwat3r.com/files, linked from the NAS tab of the Network
dashboard. The plugin only listens on port 3670, so OMV's nginx proxies
/files to it (`nas/filebrowser-nginx.conf`) and a systemd drop-in patches
the base URL the plugin hardcodes (`nas/filebrowser-baseurl.conf`). Its admin login
starts as admin/admin, change it in File Browser's settings on first login.

## Taildrop

Files sent over Tailscale to nas land in the `stuff` share under
`taildrop/`, so they show up in File Browser and in HA's /media/NAS, files
sent to ha land in /home/pi/taildrop. A `taildrop` systemd unit on each
host runs `tailscale file get --loop` as pi, without it received files sit
in tailscaled's inbox until pulled by hand. Send from any device on the
tailnet, the phone and macOS apps use the share sheet, Windows has "Send
with Tailscale" in the right-click menu, and on Linux:

    tailscale file cp <file> nas:

Files can only move between devices owned by the same tailnet user.
For uploads from a browser, File Browser at /files on the NAS already
does that over the same share.

## Glances

nas and gardener run Glances as a read-only HTTP API on port 61208, bound
to the LAN address so it is not reachable on the tailnet IP. HA polls it by
LAN IP rather than `<host>.ts.smallwat3r.com` because everything shares
one LAN: going through Tailscale would make local monitoring depend on
tailscaled and encrypt traffic that never leaves the house, while the
LAN-only bind keeps the unauthenticated API off the tailnet. glances.conf
hides filesystems, disks and interfaces that would only add noise in HA.
Entities HA already created for hidden items stay in its registry as
unavailable until deleted from the Glances entities list.
