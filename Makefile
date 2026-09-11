# Manage the Pis from this machine over the tailnet. One directory per host.
include config
REMOTE_DIR ?= /home/pi/homelab
HOST_ha = pi@ha.$(DOMAIN)
HOST_nas = pi@nas.$(DOMAIN)
HOST_gardener = pi@gardener.$(DOMAIN)
PROVISION = provision-ha provision-nas provision-gardener
GARDENER_SRC ?= $(HOME)/code/rpi-gardener

.PHONY: help lint dns push provision $(PROVISION) ivpn-conf deploy-gardener github-token forgejo-token forgejo-mirror ha-sync ha-check ha-restart ha-update ha-logs status

help:  ## Show this help menu
	@grep -hE '^[a-zA-Z_%-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "%-18s %s\n", $$1, $$2}'

lint:  ## Shellcheck every script
	shellcheck -x -s bash -P SCRIPTDIR lib.sh dns/sync.sh */setup.sh gardener/gardener-cert.sh

provision:  ## Provision every host in parallel (or provision-ha|nas|gardener), a down host doesn't block the rest
	$(MAKE) -j3 -k -O $(PROVISION)

dns:  ## Point <host>.ts.smallwat3r.com at each tailnet IP, DRY_RUN=1 to preview
	DRY_RUN=$(DRY_RUN) dns/sync.sh

cert-token-%:  ## Put the Cloudflare token from pass on a host for certbot, once (cert-token-ha|nas|gardener)
	pass show $(CF_PASS_ENTRY) | head -1 | tr -d '\r' \
	  | ssh $(HOST_$*) 'sudo install -d -m 0700 $(dir $(CF_CREDENTIALS)) \
	    && { printf "dns_cloudflare_api_token = "; cat; } \
	    | sudo sh -c "umask 077 && cat > $(CF_CREDENTIALS)"'

github-token:  ## Put the GitHub token from pass on nas for Forgejo's mirrors, once
	pass show $(GH_PASS_ENTRY) | head -1 | tr -d '\r' \
	  | ssh $(HOST_nas) 'sudo install -d -m 0700 $(dir $(GH_CREDENTIALS)) \
	    && sudo sh -c "umask 077 && cat > $(GH_CREDENTIALS)"'

# Token name carries the machine-id, hostnames alone collide (two laptops both
# called fedora). The pass entry is only written once nas returned a token, so
# a failed mint cannot blank out a token already stored
forgejo-token:  ## Mint a Forgejo push token on nas into pass for this machine's notes repo, once
	token=$$(ssh $(HOST_nas) "sudo podman exec -u git forgejo forgejo admin user generate-access-token --raw \
	    --username $(FORGEJO_USER) --token-name notes-$$(hostname)-$$(cut -c1-8 /etc/machine-id) \
	    --scopes write:repository") && [ -n "$$token" ] \
	  && printf '%s\nusername: %s\n' "$$token" $(FORGEJO_USER) | pass insert -m -f git/nas.$(DOMAIN)

forgejo-mirror:  ## Add mirrors for GitHub repos Forgejo does not have yet (also runs daily on nas)
	ssh $(HOST_nas) 'sudo forgejo-mirror'

# Table = 200 makes wg-quick put the tunnel's default route in table 200
# instead of taking over ha's own routing, DNS is dropped so ha keeps its
# resolvers (and wg-quick does not need resolvconf)
ivpn-conf:  ## Put the IVPN WireGuard config from pass on ha, once. Generate it on ivpn.net, store as ivpn/wg-ha
	pass show $(IVPN_PASS_ENTRY) | tr -d '\r' | sed '/^DNS/d; s/^\[Interface\]/&\nTable = 200/' \
	  | ssh $(HOST_ha) 'sudo install -d -m 0700 $(dir $(IVPN_CONF)) \
	    && sudo sh -c "umask 077 && cat > $(IVPN_CONF)"'

push:  ## Copy the whole repo to a host (make push HOST=pi@nas.ts.smallwat3r.com)
	rsync -a --delete --exclude .git ./ $(HOST):$(REMOTE_DIR)/

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

# What each host runs for make status, one command per line. units prints
# name and state per unit, handshake the age of the last IVPN handshake
units = for u in $(1); do printf "%-16s %s\n" $$u $$(systemctl is-active $$u); done
STATUS_ha = docker ps --format "table {{.Names}}\t{{.Status}}"; \
  tailscale status --self | head -1; \
  $(call units,taildrop wg-quick@ivpn certbot.timer); \
  echo "ivpn handshake   $$(( $$(date +%s) - $$(sudo wg show ivpn latest-handshakes | cut -f2) ))s ago"; \
  sudo iptables -S FORWARD | sed -n 2p; \
  findmnt -t cifs -no SOURCE,FSTYPE /mnt/nas/stuff || echo "nas share not mounted"
STATUS_nas = $(call units,glances pod-filebrowser forgejo taildrop certbot.timer); \
  curl -s -m 3 http://$(NAS_IP):$(GLANCES_PORT)/api/4/status; echo
STATUS_gardener = $(call units,glances certbot.timer); \
  curl -s -m 3 http://$(GARDENER_IP):$(GLANCES_PORT)/api/4/status; echo

status:  ## Quick health check of all hosts
	@echo "== ha"; ssh $(HOST_ha) '$(STATUS_ha)'
	@echo "== nas"; ssh $(HOST_nas) '$(STATUS_nas)'
	@echo "== gardener"; ssh $(HOST_gardener) '$(STATUS_gardener)'
