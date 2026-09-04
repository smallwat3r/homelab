# Manage the Pis from this machine over the tailnet. One directory per host.
include hosts.conf
REMOTE_DIR ?= /home/pi/homelab
HOST_master = capo.ts
HOST_nas = nas.ts
HOST_gardener = gardener.ts
PROVISION = provision-master provision-nas provision-gardener
HA_DIR = /opt/homeassistant
HA_CONFIG_DIR = $(HA_DIR)/config

.PHONY: push $(PROVISION) ha-sync ha-check ha-restart ha-logs status

# Copy the whole repo to a host, make push HOST=nas.ts
push:
	rsync -a --delete --exclude .git ./ $(HOST):$(REMOTE_DIR)/

# Full provisioning, idempotent, safe to rerun
$(PROVISION): provision-%:
	$(MAKE) push HOST=$(HOST_$*)
	ssh $(HOST_$*) '$(REMOTE_DIR)/$*/setup.sh'

# Push Home Assistant config files, validate, then restart
ha-sync:
	$(MAKE) push HOST=$(HOST_master)
	ssh $(HOST_master) 'cp $(REMOTE_DIR)/master/homeassistant/compose.yaml $(HA_DIR)/ \
	  && cp $(REMOTE_DIR)/master/homeassistant/configuration.yaml $(HA_CONFIG_DIR)/ \
	  && cp $(REMOTE_DIR)/master/homeassistant/dashboards/*.yaml $(HA_CONFIG_DIR)/dashboards/'
	$(MAKE) ha-check ha-restart

ha-check:
	ssh $(HOST_master) 'docker exec homeassistant python -m homeassistant --script check_config -c /config'

ha-restart:
	ssh $(HOST_master) 'docker compose --project-directory $(HA_DIR) restart'

ha-logs:
	ssh $(HOST_master) 'docker logs -f --tail 100 homeassistant'

status:
	ssh $(HOST_master) 'docker ps --format "table {{.Names}}\t{{.Status}}"; tailscale status --self | head -1; sudo iptables -S FORWARD | sed -n 2p'
	ssh $(HOST_nas) 'systemctl is-active glances; curl -s -m 3 http://$(NAS_IP):61208/api/4/status; echo'
	ssh $(HOST_gardener) 'systemctl is-active glances; curl -s -m 3 http://$(GARDENER_IP):61208/api/4/status; echo'
