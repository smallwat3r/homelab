# Manage the Pis from this machine over the tailnet. One directory per host.
include hosts.conf
REMOTE_DIR ?= /home/pi/homelab
TAILNET = feist-corn.ts.net
HOST_master = pi@capo.$(TAILNET)
HOST_nas = pi@nas.$(TAILNET)
HOST_gardener = pi@gardener.$(TAILNET)
PROVISION = provision-master provision-nas provision-gardener
HA_DIR = /opt/homeassistant
HA_CONFIG_DIR = $(HA_DIR)/config
GARDENER_SRC ?= $(HOME)/code/rpi-gardener

.PHONY: help push provision $(PROVISION) deploy-gardener ha-sync ha-check ha-restart ha-logs status

help:  ## Show this help menu
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "%-18s %s\n", $$1, $$2}'

provision: $(PROVISION)  ## Provision every host (or provision-master|nas|gardener), idempotent

push:  ## Copy the whole repo to a host (make push HOST=nas.ts)
	rsync -a --delete --exclude .git --filter=':- .gitignore' ./ $(HOST):$(REMOTE_DIR)/

$(PROVISION): provision-%:
	$(MAKE) push HOST=$(HOST_$*)
	ssh $(HOST_$*) '$(REMOTE_DIR)/$*/setup.sh'

# Its own make deploy provisions the Pi, syncs the code and restarts the stack
deploy-gardener:  ## Deploy the rpi-gardener app to the gardener Pi (clones the repo if missing)
	test -d $(GARDENER_SRC) || git clone https://github.com/smallwat3r/rpi-gardener.git $(GARDENER_SRC)
	$(MAKE) -C $(GARDENER_SRC) deploy DEPLOY_HOST=$(HOST_gardener)

ha-sync:  ## Push Home Assistant config files, validate, then restart
	$(MAKE) push HOST=$(HOST_master)
	ssh $(HOST_master) 'cp $(REMOTE_DIR)/master/homeassistant/compose.yaml $(HA_DIR)/ \
	  && cp $(REMOTE_DIR)/master/homeassistant/configuration.yaml $(HA_CONFIG_DIR)/ \
	  && cp $(REMOTE_DIR)/master/homeassistant/dashboards/*.yaml $(HA_CONFIG_DIR)/dashboards/'
	$(MAKE) ha-check ha-restart

ha-check:  ## Validate the Home Assistant config
	ssh $(HOST_master) 'docker exec homeassistant python -m homeassistant --script check_config -c /config'

ha-restart:  ## Restart the Home Assistant container
	ssh $(HOST_master) 'docker compose --project-directory $(HA_DIR) restart'

ha-logs:  ## Tail the Home Assistant container logs
	ssh $(HOST_master) 'docker logs -f --tail 100 homeassistant'

status:  ## Quick health check of all hosts
	ssh $(HOST_master) 'docker ps --format "table {{.Names}}\t{{.Status}}"; tailscale status --self | head -1; sudo iptables -S FORWARD | sed -n 2p'
	ssh $(HOST_nas) 'systemctl is-active glances; curl -s -m 3 http://$(NAS_IP):61208/api/4/status; echo'
	ssh $(HOST_gardener) 'systemctl is-active glances; curl -s -m 3 http://$(GARDENER_IP):61208/api/4/status; echo'
