LAB_COMPOSE := docker compose -f infra/lab/compose.yaml
DB_COMPOSE := docker compose --env-file .env -f infra/engine/compose.yaml

.DEFAULT_GOAL := help

.PHONY: help lab-help db-help \
				lab-up lab-check lab-down lab-reset lab-rotate-key \
				db-up db-check db-down db-reset db-psql db-logs \
				require-env

help:
	@echo 'shipyard'
	@$(MAKE) --no-print-directory lab-help
	@$(MAKE) --no-print-directory db-help

lab-help:
	@echo ''
	@echo '  lab — deployment targets (a fixture)'
	@echo '  make lab-up           build and start the fleet, capture host keys'
	@echo '  make lab-check        assert the fleet is a usable deployment target'
	@echo '  make lab-down         stop the fleet, keep keys and host identities'
	@echo '  make lab-reset        stop and discard volumes (rotates host keys)'
	@echo '  make lab-rotate-key   revoke the login keypair'

db-help:
	@echo ''
	@echo '  db — the ledger (engine infrastructure)'
	@echo '  make db-up           start Postgres and wait until it is healthy'
	@echo '  make db-check				assert the ledger answers a real query'
	@echo '  make db-down					stop it, keep the data'
	@echo '  make db-reset				stop it and discard the volume (clean ledger)'
	@echo '  make db-psql					open a psql session against it'
	@echo '  make db-logs 				tail its logs'

lab-up:
	$(LAB_COMPOSE) up -d
	@$(MAKE) --no-print-directory lab-check

lab-check:
	$(LAB_COMPOSE) run --rm --no-deps --build known-hosts check

lab-down:
	$(LAB_COMPOSE) down

lab-reset:
	$(LAB_COMPOSE) down -v --remove-orphans

lab-rotate-key:
	$(LAB_COMPOSE) run --rm --no-deps keys rotate

require-env:
	@test -f .env || { echo 'no .env found - run: cp .env.example .env'; exit 1; }

db-up: require-env
	$(DB_COMPOSE) up -d --wait --wait-timeout 60

db-check: require-env
	$(DB_COMPOSE) exec -T postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" -tAc "show server_version"' > /dev/null \
		|| { echo 'FAIL: ledger is not answering queries'; exit 1; }
	@$(DB_COMPOSE) ps
	@echo 'Ledger ready.'

db-down: require-env
	$(DB_COMPOSE) down

db-reset: require-env
	$(DB_COMPOSE) down -v --remove-orphans

db-psql: require-env
	$(DB_COMPOSE) exec postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

db-logs: require-env
	$(DB_COMPOSE) logs -f postgres
