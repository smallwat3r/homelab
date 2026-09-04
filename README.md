# homelab

Config and provisioning for the Raspberry Pis on the home network, managed
from this machine over the tailnet. One directory per host, `lib.sh` holds
helpers shared by the setup scripts, `hosts.conf` the LAN addresses.

| Directory | Tailnet host | Role |
|-----------|--------------|------|
| master    | capo     | Tailscale subnet router and exit node, Home Assistant Container |
| nas       | nas      | OpenMediaVault, Glances for HA |
| gardener  | gardener | rpi-gardener containers, Glances for HA |

## Usage

```
make provision        # provision every host, idempotent
make provision-<dir>  # rsync the repo to the host and run its setup.sh, idempotent
make deploy-gardener  # deploy smallwat3r/rpi-gardener to the gardener Pi
make ha-sync          # push Home Assistant config, validate, restart
make ha-logs          # tail the Home Assistant container logs
make status           # quick health check of all hosts
```

Home Assistant lives at https://capo.feist-corn.ts.net, served over the
tailnet by tailscale serve. Its runtime state stays on the Pi under
/opt/homeassistant, only compose.yaml, configuration.yaml and the dashboards
are repo-managed.
