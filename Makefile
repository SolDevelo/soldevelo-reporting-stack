COMPOSE_DIR := compose
COMPOSE_CMD := docker compose --env-file .env -f $(COMPOSE_DIR)/docker-compose.yml

.PHONY: up down ps logs restart reset build setup recover verify-services verify-cdc verify-ingestion verify-dbt verify-airflow verify-superset verify-packages clickhouse-init dbt-build dbt-test register-connector connector-status delete-connector connector-refresh superset-import package-fetch package-validate

up: ## Start all services
	@docker network inspect reporting-shared > /dev/null 2>&1 || \
		docker network create --label com.docker.compose.network=reporting-shared reporting-shared > /dev/null
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

recover: ## Restore a broken pipeline: verify services, re-register connector, restart failed tasks, verify CDC + ingestion
	@bash scripts/recover.sh

verify-services: ## Verify platform services are healthy (Kafka, Connect, Apicurio, Kafka UI, ClickHouse)
	@bash scripts/verify/services.sh

verify-cdc: ## Verify Debezium CDC connector is running and topics exist
	@bash scripts/verify/cdc.sh

verify-ingestion: ## Verify ClickHouse raw landing tables have data
	@bash scripts/verify/ingestion.sh

dbt-build: ## Run dbt build (deps + build)
	@bash scripts/dbt/build.sh

verify-dbt: ## Verify dbt models built successfully and curated marts have data
	@bash scripts/verify/dbt.sh

verify-airflow: ## Verify Airflow is healthy and platform_refresh DAG is registered
	@bash scripts/verify/airflow.sh

dbt-test: ## Run dbt tests only
	@bash scripts/dbt/test.sh

clickhouse-init: ## Initialize ClickHouse databases and raw landing tables
	@bash scripts/clickhouse/init.sh

register-connector: ## Register the Debezium CDC connector
	@bash scripts/connect/register-connector.sh

connector-status: ## Show CDC connector status
	@bash scripts/connect/status.sh

delete-connector: ## Delete the CDC connector
	@bash scripts/connect/delete-connector.sh

connector-refresh: ## Reset connector offsets and re-snapshot all tables (use after adding new tables)
	@bash scripts/connect/refresh-connector.sh

superset-import: ## Import Superset assets (platform → core → extensions)
	@bash scripts/superset/import-all.sh

verify-superset: ## Verify Superset is healthy and assets are imported
	@bash scripts/verify/superset.sh

package-fetch: ## Fetch analytics packages from Git (requires ANALYTICS_CORE_GIT_URL)
	@bash scripts/packages/fetch.sh

package-validate: ## Validate extension packages (extend-only enforcement)
	@bash scripts/packages/validate.sh

verify-packages: ## Verify analytics packages: validate + build + import + check dashboards
	@bash scripts/verify/packages.sh
