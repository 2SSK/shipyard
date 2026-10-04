COMPOSE := docker compose -f infra/lab/compose.yaml

.DEFAULT_GOAL := lab-help
.PHONY: lab-help lab-up lab-check lab-down lab-reset lab-rotate-key

lab-help:
	@echo 'shipyard lab'
	@echo '  make lab-up           build and start the fleet, capture host keys'
	@echo '  make lab-check        assert the fleet is a usable deployment target'
	@echo '  make lab-down         stop the fleet, keep keys and host identities'
	@echo '  make lab-reset        stop and discard volumes (rotates host keys)'
	@echo '  make lab-rotate-key   revoke the login keypair'

lab-up:
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory lab-check

# --no-deps on purpose: check must report the lab as it finds it, not quietly
# start the fleet it was asked to verify. --build because the check script is
# baked into the init image, and a stale one would silently assert old behaviour.
lab-check:
	$(COMPOSE) run --rm --no-deps --build known-hosts check

lab-down:
	$(COMPOSE) down

lab-reset:
	$(COMPOSE) down -v --remove-orphans

lab-rotate-key:
	$(COMPOSE) run --rm --no-deps keys rotate
