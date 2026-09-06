# Manage the Pis from this machine over the tailnet. One directory per host.
include config
REMOTE_DIR ?= /home/pi/homelab
HOST_ha = pi@ha.$(DOMAIN)
HOST_nas = pi@nas.$(DOMAIN)
HOST_gardener = pi@gardener.$(DOMAIN)
PROVISION = provision-ha provision-nas provision-gardener
GARDENER_SRC ?= $(HOME)/code/rpi-gardener

.PHONY: help lint dns push provision $(PROVISION) deploy-gardener ha-sync ha-check ha-restart ha-update ha-logs status

help:  ## Show this help menu
	@grep -hE '^[a-zA-Z_%-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "%-18s %s\n", $$1, $$2}'

lint:  ## Shellcheck every script
	shellcheck -x -s bash -P SCRIPTDIR lib.sh dns/sync.sh */setup.sh

provision:  ## Provision every host in parallel (or provision-ha|nas|gardener), a down host doesn't block the rest
	$(MAKE) -j3 -k -O $(PROVISION)

dns:  ## Point <host>.ts.smallwat3r.com at each tailnet IP, DRY_RUN=1 to preview
	DRY_RUN=$(DRY_RUN) dns/sync.sh

cert-token-%:  ## Put the Cloudflare token from pass on a host for certbot, once (cert-token-ha|nas)
	pass show $(CF_PASS_ENTRY) | head -1 | tr -d '\r' \
	  | ssh $(HOST_$*) 'sudo install -d -m 0700 $(dir $(CF_CREDENTIALS)) \
	    && { printf "dns_cloudflare_api_token = "; cat; } \
	    | sudo sh -c "umask 077 && cat > $(CF_CREDENTIALS)"'

push:  ## Copy the whole repo to a host (make push HOST=pi@nas.ts.smallwat3r.com)
	rsync -a --delete --exclude .git --filter=':- .gitignore' ./ $(HOST):$(REMOTE_DIR)/

$(PROVISION): provision-%:
	$(MAKE) push HOST=$(HOST_$*)
	ssh $(HOST_$*) '$(REMOTE_DIR)/$*/setup.sh'

# Its own make deploy provisions the Pi, syncs the code and restarts the stack
deploy-gardener:  ## Deploy the rpi-gardener app to the gardener Pi (clones the repo if missing)
	test -d $(GARDENER_SRC) || git clone https://github.com/smallwat3r/rpi-gardener.git $(GARDENER_SRC)
	$(MAKE) -C $(GARDENER_SRC) deploy DEPLOY_HOST=$(HOST_gardener)

ha-sync:  ## Push Home Assistant config and compose files, validate, then recreate the container
	rsync -a --exclude compose.yaml ha/homeassistant/ $(HOST_ha):$(HA_CONFIG_DIR)/
	rsync -a ha/homeassistant/compose.yaml $(HOST_ha):$(HA_DIR)/
	$(MAKE) ha-check
	ssh $(HOST_ha) 'docker compose --project-directory $(HA_DIR) up -d --force-recreate'

ha-check:  ## Validate the Home Assistant config
	ssh $(HOST_ha) 'docker exec homeassistant python -m homeassistant --script check_config -c /config'

ha-restart:  ## Restart the Home Assistant container
	ssh $(HOST_ha) 'docker compose --project-directory $(HA_DIR) restart'

ha-update:  ## Pull the latest Home Assistant image and recreate the container
	ssh $(HOST_ha) 'docker compose --project-directory $(HA_DIR) pull && docker compose --project-directory $(HA_DIR) up -d'

ha-logs:  ## Tail the Home Assistant container logs
	ssh $(HOST_ha) 'docker logs -f --tail 100 homeassistant'

status:  ## Quick health check of all hosts
	ssh $(HOST_ha) 'docker ps --format "table {{.Names}}\t{{.Status}}"; tailscale status --self | head -1; systemctl is-active taildrop; sudo iptables -S FORWARD | sed -n 2p; findmnt -no SOURCE,FSTYPE /mnt/nas/stuff || echo "nas share not mounted"'
	ssh $(HOST_nas) 'systemctl is-active glances pod-filebrowser taildrop | paste - - -; curl -s -m 3 http://$(NAS_IP):$(GLANCES_PORT)/api/4/status; echo'
	ssh $(HOST_gardener) 'systemctl is-active glances; curl -s -m 3 http://$(GARDENER_IP):$(GLANCES_PORT)/api/4/status; echo'
