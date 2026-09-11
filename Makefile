# Manage the Pis from this machine over the tailnet. One directory per host.
include config
REMOTE_DIR ?= /home/pi/homelab
# A host is a directory with a setup.sh, each gets HOST_<name> and provision-<name>
HOSTS = $(patsubst %/setup.sh,%,$(wildcard */setup.sh))
$(foreach h,$(HOSTS),$(eval HOST_$(h) = pi@$(h).$(DOMAIN)))
PROVISION = $(addprefix provision-,$(HOSTS))
GARDENER_SRC ?= $(HOME)/code/rpi-gardener
# First line of a pass entry, without the CR pass sometimes leaves
entry = pass show $(1) | head -1 | tr -d '\r'
# Pipe stdin onto a host as a root-only file, with an optional prefix
secret = ssh $(1) 'sudo install -d -m 0700 $(dir $(2)) && { printf "%s" "$(3)"; cat; } | sudo sh -c "umask 077 && cat > $(2)"'

.PHONY: help lint dns push provision $(PROVISION) ivpn-conf slack-webhook deploy-gardener github-token forgejo-token forgejo-mirror ha-sync ha-check ha-restart ha-update ha-logs status

help:  ## Show this help menu
	@grep -hE '^[a-zA-Z_%-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "%-18s %s\n", $$1, $$2}'

lint:  ## Shellcheck every script, ruff and mypy the Python ones
	shellcheck -x -s bash -P SCRIPTDIR lib.sh */setup.sh */status.sh
	shellcheck -s sh ha/ivpn-ctl gardener/gardener-cert.sh
	ruff check
	mypy --strict .

provision:  ## Provision every host in parallel (or provision-<host>), a down host doesn't block the rest
	$(MAKE) -j$(words $(HOSTS)) -k -O $(PROVISION)

dns:  ## Point <host>.ts.smallwat3r.com at each tailnet IP, DRY_RUN=1 to preview
	DRY_RUN=$(DRY_RUN) ./dns-sync.py $(HOSTS)

cert-token-%:  ## Put the Cloudflare token from pass on a host for certbot, once (cert-token-<host>)
	$(call entry,$(CF_PASS_ENTRY)) | $(call secret,$(HOST_$*),$(CF_CREDENTIALS),dns_cloudflare_api_token = )

github-token:  ## Put the GitHub token from pass on nas for Forgejo's mirrors, once
	$(call entry,$(GH_PASS_ENTRY)) | $(call secret,$(HOST_nas),$(GH_CREDENTIALS))

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
	  | $(call secret,$(HOST_ha),$(IVPN_CONF))

slack-webhook:  ## Put the Slack incoming webhook URL from pass on lookout for the watchdog, once
	$(call entry,$(SLACK_PASS_ENTRY)) | $(call secret,$(HOST_lookout),$(SLACK_CONF),SLACK_WEBHOOK=)

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

status:  ## Quick health check of all hosts, each runs its status.sh from the last push
	@$(foreach h,$(HOSTS),echo "== $(h)"; ssh $(HOST_$(h)) '$(REMOTE_DIR)/$(h)/status.sh';)
