# homelab

Config and provisioning for the Raspberry Pis at home. One directory per
host with an idempotent `setup.sh`, `lib.sh` for shared helpers, `config`
for shared facts (domain, LAN IPs, ports, paths), `dns-sync.py` behind
`make dns` and `taildrop.service` installed on ha and nas. `make help`
lists the targets.

| Directory | Role |
|-----------|------|
| ha        | Tailscale subnet router and exit node through IVPN, Home Assistant Container, TLS certificate |
| nas       | OpenMediaVault, File Browser, Forgejo mirroring GitHub |
| gardener  | rpi-gardener containers, TLS certificate for its nginx |
| lookout   | Standby subnet router while ha is down, watchdog alerting on Slack with a status page |

Every target reaches a host as `pi@<host>.ts.smallwat3r.com`, so a fresh
Pi needs Tailscale installed and joined to the tailnet, then `make dns`,
before `make provision-<host>` works. `make provision` does every host.

## Access

Everything lives on the tailnet, nothing is reachable from the internet.
`<host>.ts.smallwat3r.com` are public A records in Cloudflare that point at
the tailnet IPs, public because each host runs certbot for a Let's
Encrypt wildcard on `*.ts.smallwat3r.com` via the DNS-01 challenge. They
resolve anywhere but only answer from a device on the tailnet. `make dns`
keeps them in sync, Tailscale's split DNS sends the domain to Cloudflare's
resolvers.

- https://ha.ts.smallwat3r.com, Home Assistant
- https://nas.ts.smallwat3r.com, OpenMediaVault
- https://nas.ts.smallwat3r.com/files, File Browser over the `stuff` share
- https://nas.ts.smallwat3r.com/git, Forgejo
- https://gardener.ts.smallwat3r.com, rpi-gardener, deploy it with
  `make deploy-gardener` before `make provision-gardener`, which puts the
  certificate into its nginx
- https://lookout.ts.smallwat3r.com, the watchdog's status page

File Browser's admin login starts as admin/admin, change it in Settings >
User management right after provisioning, it has write access to the whole
share.

## Secrets

All live in pass and are copied to the host once, setup.sh never touches
them.

- `cloudflare/ts-dns`, the Cloudflare DNS token for certbot,
  `make cert-token-ha`, `make cert-token-nas`, `make cert-token-gardener` and
  `make cert-token-lookout`
- `ivpn/wg-ha`, the IVPN WireGuard config, `make ivpn-conf`
- `slack/homelab-webhook`, the Slack incoming webhook the watchdog posts to,
  `make slack-webhook`
- `github/forgejo-mirror`, a GitHub token that can read every repo (classic
  `repo` scope, or fine-grained with Contents and Metadata read on all
  repos), `make github-token`

## IVPN

ha's exit node goes out through an IVPN WireGuard tunnel, so any device
that picks ha as its exit node is behind IVPN without running the IVPN
client, and IVPN counts one device for all of them. ha's own traffic stays
direct.

Setup: generate a WireGuard config on the IVPN account page, enable IPv6 in
the generator if it offers it (otherwise clients' IPv6 traffic is dropped
rather than falling back), store it whole in pass as `ivpn/wg-ha` and run
`make ivpn-conf`. The key is account wide, so the tunnel can be moved
between servers without a new config.

Drive the tunnel with `ivpn-ctl` on ha, never systemctl: a tunnel that goes
down any other way blocks exit node traffic rather than leaking it.

- `ivpn-ctl server`, show the current server
- `ivpn-ctl server gb`, move to another server, codes are the gateways in
  IVPN's server list
- `ivpn-ctl stop`, send exit node traffic straight out through the router
- `ivpn-ctl start`, put it back through IVPN

The Network dashboard has a switch for the tunnel and a server dropdown, HA
drives both over ssh to its own host with a key that can only run
`ivpn-ctl`.

## Lookout

The Pi 3A+ stands in for ha as subnet router, without the exit node, so
the LAN stays reachable while ha reboots or is broken. Tailscale picks any
approved router as primary and never fails back, so lookout only
advertises the subnet while the watchdog sees ha down, and withdraws it
when ha answers again. Approve its route once in the Tailscale admin
console, provisioning advertises it so it shows up there.

Every two minutes it fetches ha, nas, File Browser and Forgejo on nas, and
gardener over the tailnet, and posts to Slack when one goes down or comes
back. Create an app at
api.slack.com with Incoming Webhooks on, add a webhook to a channel, store
its URL in pass as `slack/homelab-webhook` and run `make slack-webhook`.
The URL is the only thing guarding the channel. Each run also rewrites the
status page nginx serves at https://lookout.ts.smallwat3r.com, service,
state and time of the last change. Nothing watches lookout itself. To
spare the SD card its journal lives in RAM, Slack is the durable log, and
nginx keeps no access log.

## SD cards

Every Pi boots from an SD card, so nothing that writes constantly may live
on it. Swap is zram everywhere. ha, gardener and lookout keep the journal
in RAM, and docker on ha logs to the journal instead of json files,
`make ha-sync` recreates the container so it picks that up, gardener's
compose file caps its own. nas needs none of it, OpenMediaVault keeps /var/log
and its databases in a RAM write cache and Forgejo's data is on the disk.
Home Assistant's recorder is the one real writer left, it commits every
five minutes and keeps three days, and its ssh polling of the IVPN switch
is slowed down since every poll is a logged login. lookout's nginx keeps
no access log.

## Forgejo

A pull mirror of every GitHub repo the account owns, forks excluded, on
the NAS disk under `forgejo/` next to the share. Every mirror is public,
private GitHub repos included, since only the tailnet can reach it, so
browsing and cloning need no login. It is browse-only, issues, pull
requests, wikis, packages and actions are all off. Forgejo runs as a podman
quadlet, HTTPS only, and `forgejo-mirror` adds any repo GitHub has that
Forgejo does not, daily from cron and from `make forgejo-mirror`. Forgejo
resyncs each mirror every 8 hours. Mirrors are read-only, keep pushing to
GitHub as usual, issues and pull requests are not mirrored.

The first provision prints the owner's random password, the web UI asks to
change it on first login. Registration is off, add users from Site
administration.

### Notes

`~/notes` on a laptop is a private repo on Forgejo, pushed over HTTPS with
a token. Emacs keeps org, journal and deft under it, anything else (md,
txt, whatever) goes alongside. `make forgejo-token` mints a token on nas
(named after the hostname and machine-id, so same-named laptops do not
clash) and stores it in pass as `git/nas.ts.smallwat3r.com`, where the
dotfiles' `git-credential-pass` helper finds it. Pushing creates the repo, so the
first laptop pushes:

    git -C ~/notes remote add origin https://nas.ts.smallwat3r.com/git/smallwat3r/notes.git
    git -C ~/notes push -u origin main

and any other laptop clones that URL to `~/notes`. From there the
`notes-sync` user timer from the dotfiles commits, pulls and pushes every
15 minutes, a conflict stops it until fixed by hand. The mirror job leaves it alone, it only adds repos GitHub
has that Forgejo does not.

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
- HACS > Integrations: Octopus Energy, then add it with the API key and
  account number from the Octopus account page.
- Rename the two Glances devices to `nas` and `gardener`, accepting the
  entity id rename, the Network dashboard uses `sensor.nas_*` and
  `sensor.gardener_*` rather than ids built from the LAN IPs.
- Developer tools > Actions: `frontend.set_theme` with name `Terminal`.

The NAS `stuff` share is mounted on ha over SMB and shows in HA's Media
browser as NAS. The Media browser only lists images, audio and video, use
File Browser for everything else.

## Taildrop

Files sent over Tailscale land in the `stuff` share under `taildrop/` on
nas, and in /home/pi/taildrop on ha. From Linux:

    tailscale file cp <file> nas:
