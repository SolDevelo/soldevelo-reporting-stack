COMPOSE_DIR := compose
COMPOSE_CMD := docker compose --env-file .env -f $(COMPOSE_DIR)/docker-compose.yml

.PHONY: up down ps logs restart reset build setup verify-services verify-cdc verify-ingestion clickhouse-init register-connector connector-status delete-connector

up: ## Start all services
	$(COMPOSE_CMD) up -d

down: ## Stop all services
	$(COMPOSE_CMD) down

ps: ## Show running services
	$(COMPOSE_CMD) ps

logs: ## Tail logs (pass SVC=<name> to filter)
	$(COMPOSE_CMD) logs -f $(SVC)

restart: ## Restart all services (or SVC=<name>)
	$(COMPOSE_CMD) restart $(SVC)

reset: ## Stop services and wipe all volumes
	$(COMPOSE_CMD) down -v --remove-orphans

build: ## Build/rebuild service images (or SVC=<name>)
	$(COMPOSE_CMD) build $(SVC)

setup: ## Configure platform: register connector + init ClickHouse + verify
	@bash scripts/setup.sh

verify-services: ## Verify platform services are healthy (Kafka, Connect, Apicurio, Kafka UI, ClickHouse)
	@bash scripts/verify/services.sh

verify-cdc: ## Verify Debezium CDC connector is running and topics exist
	@bash scripts/verify/cdc.sh

verify-ingestion: ## Verify ClickHouse raw landing tables have data
	@bash scripts/verify/ingestion.sh

clickhouse-init: ## Initialize ClickHouse databases and raw landing tables
	@bash scripts/clickhouse/init.sh

register-connector: ## Register the Debezium CDC connector
	@bash scripts/connect/register-connector.sh

connector-status: ## Show CDC connector status
	@bash scripts/connect/status.sh

delete-connector: ## Delete the CDC connector
	@bash scripts/connect/delete-connector.sh
