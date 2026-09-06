# homelab

Config and provisioning for the Raspberry Pis at home. One directory per
host with an idempotent `setup.sh`, `lib.sh` for shared helpers, `config`
for shared facts (domain, LAN IPs, ports, paths). `make help` lists the
targets.

| Directory | Role |
|-----------|------|
| ha        | Tailscale subnet router and exit node, Home Assistant Container, TLS certificate |
| nas       | OpenMediaVault, File Browser |
| gardener  | rpi-gardener containers |

## Access

Everything lives on the tailnet, nothing is reachable from the internet.
`<host>.ts.smallwat3r.com` are public A records in Cloudflare that point at
the tailnet IPs, so they resolve anywhere but only answer from a device on
the tailnet. `make dns` keeps them in sync, Tailscale's split DNS sends the
domain to Cloudflare's resolvers. ha holds a Let's Encrypt wildcard for
`*.ts.smallwat3r.com` via the DNS-01 challenge, which is why the records
have to be public.

- https://ha.ts.smallwat3r.com, Home Assistant
- http://nas.ts.smallwat3r.com, OpenMediaVault, `/files` is File Browser
  over the `stuff` share
- https://gardener.feist-corn.ts.net, rpi-gardener

The only secret is the Cloudflare DNS token in pass as `cloudflare/ts-dns`,
`make cert-token` copies it to ha once for certbot.

## Home Assistant

Runtime state stays on the Pi under /opt/homeassistant. Repo-managed:
compose.yaml, configuration.yaml, dashboards, the Terminal theme and the
ocrab font. `make ha-sync` pushes them, `make ha-update` pulls the latest
image. HACS and eero are installed into custom_components by setup.sh.

One-time steps in the UI that setup.sh cannot do:

- Settings > System > Network: port 443, certificate and key from
  `/etc/letsencrypt/live/ts.smallwat3r.com/`.
- Add integrations: HACS, eero, Glances for nas and gardener (LAN IP from
  `config`, port 61208), System Monitor for ha. System Monitor's sensors
  are disabled by default, enable the ones on the Network dashboard.
- Rename the two Glances devices to `nas` and `gardener`, accepting the
  entity id rename, the Network dashboard uses `sensor.nas_*` and
  `sensor.gardener_*` rather than ids built from the LAN IPs.
- Developer tools > Actions: `frontend.set_theme` with name `Terminal`.

The NAS `stuff` share is mounted on ha over SMB and shows in HA's Media
browser as NAS. The Media browser only lists images, audio and video, use
File Browser for everything else. Its admin login starts as admin/admin,
change it in Settings > User management right after provisioning, it has
write access to the whole share.

## Taildrop

Files sent over Tailscale land in the `stuff` share under `taildrop/` on
nas, and in /home/pi/taildrop on ha. From Linux:

    tailscale file cp <file> nas:
