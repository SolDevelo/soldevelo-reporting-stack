COMPOSE_DIR := compose
COMPOSE_CMD := docker compose --env-file .env -f $(COMPOSE_DIR)/docker-compose.yml

.PHONY: up down ps logs restart reset build lint verify step1 step2 register-connector connector-status delete-connector

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

lint: ## Run linters (placeholder)
	@echo "lint: no linters configured yet"

verify: ## Run verification checks (placeholder)
	@echo "verify: no checks configured yet"

step1: ## Verify Step 1: base platform services
	@bash scripts/verify/step1.sh

step2: ## Verify Step 2: Debezium CDC connector
	@bash scripts/verify/step2.sh

register-connector: ## Register the Debezium CDC connector
	@bash scripts/connect/register-connector.sh

connector-status: ## Show CDC connector status
	@bash scripts/connect/status.sh

delete-connector: ## Delete the CDC connector
	@bash scripts/connect/delete-connector.sh
