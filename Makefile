# ============================================
# Homelab - Service Orchestration
# ============================================
# Usage:
#   make setup          - First-time setup (network + .env files)
#   make up             - Start all services
#   make down           - Stop all services
#   make restart        - Restart all services
#   make pull           - Pull latest images for all services
#   make status         - Show running containers
#   make up-<service>   - Start a single service
#   make down-<service> - Stop a single service
#   make logs-<service> - Tail logs for a service
# ============================================

COMPOSE = docker compose
SERVICES_DIR = services

# Auto-discover services (each subdirectory under services/)
SERVICES := $(notdir $(patsubst %/,%,$(wildcard $(SERVICES_DIR)/*/)))

.PHONY: help setup network check-env-files up down restart pull status clean $(foreach s,$(SERVICES),up-$(s) down-$(s) restart-$(s) logs-$(s) pull-$(s))

help:
	@echo ""
	@echo "Homelab Management"
	@echo "=================="
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Per-service targets (replace <service> with: $(SERVICES)):"
	@echo "  up-<service>       Start a specific service"
	@echo "  down-<service>     Stop a specific service"
	@echo "  restart-<service>  Restart a specific service"
	@echo "  logs-<service>     Tail logs for a specific service"
	@echo "  pull-<service>     Pull latest image for a specific service"
	@echo ""

# --------------------------------------------------
# Setup
# --------------------------------------------------

setup: network env-files ## First-time setup: create network and .env files
	@echo "Setup complete. Review .env files in each service directory, then run: make up"

network: ## Create the shared homelab Docker network
	@docker network inspect homelab >/dev/null 2>&1 || docker network create homelab
	@echo "Network 'homelab' is ready."

env-files: ## Copy .env.example -> .env for services missing a .env
	@for dir in $(SERVICES_DIR)/*/; do \
		if [ -f "$$dir/.env.example" ] && [ ! -f "$$dir/.env" ]; then \
			cp "$$dir/.env.example" "$$dir/.env"; \
			echo "Created $$dir.env from example"; \
		fi; \
	done

# --------------------------------------------------
# All-service commands
# --------------------------------------------------

check-env-files: ## Verify all service .env files exist
	@missing=0; \
	for svc in $(SERVICES); do \
		if [ ! -f "$(SERVICES_DIR)/$$svc/.env" ]; then \
			echo "ERROR: Missing .env for '$$svc'. Run 'make setup' or:"; \
			echo "       cp $(SERVICES_DIR)/$$svc/.env.example $(SERVICES_DIR)/$$svc/.env"; \
			missing=1; \
		fi; \
	done; \
	if [ $$missing -ne 0 ]; then exit 1; fi

up: network check-env-files ## Start all services
	@for svc in $(SERVICES); do \
		echo "Starting $$svc..."; \
		$(COMPOSE) -f $(SERVICES_DIR)/$$svc/docker-compose.yml --env-file $(SERVICES_DIR)/$$svc/.env up -d; \
	done

down: ## Stop all services
	@for svc in $(SERVICES); do \
		echo "Stopping $$svc..."; \
		$(COMPOSE) -f $(SERVICES_DIR)/$$svc/docker-compose.yml --env-file $(SERVICES_DIR)/$$svc/.env down; \
	done

restart: down up ## Restart all services

pull: ## Pull latest images for all services
	@for svc in $(SERVICES); do \
		echo "Pulling $$svc..."; \
		$(COMPOSE) -f $(SERVICES_DIR)/$$svc/docker-compose.yml pull; \
	done

status: ## Show running containers
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

clean: ## Stop all services and remove the homelab network
	@$(MAKE) down
	@docker network rm homelab 2>/dev/null || true
	@echo "Cleaned up."

# --------------------------------------------------
# Per-service commands (dynamically generated)
# --------------------------------------------------

define SERVICE_TARGETS
up-$(1): network check-env-files ## Start $(1)
	$(COMPOSE) -f $(SERVICES_DIR)/$(1)/docker-compose.yml --env-file $(SERVICES_DIR)/$(1)/.env up -d

down-$(1): ## Stop $(1)
	$(COMPOSE) -f $(SERVICES_DIR)/$(1)/docker-compose.yml --env-file $(SERVICES_DIR)/$(1)/.env down

restart-$(1): down-$(1) up-$(1) ## Restart $(1)

logs-$(1): ## Tail logs for $(1)
	$(COMPOSE) -f $(SERVICES_DIR)/$(1)/docker-compose.yml --env-file $(SERVICES_DIR)/$(1)/.env logs -f

pull-$(1): ## Pull latest image for $(1)
	$(COMPOSE) -f $(SERVICES_DIR)/$(1)/docker-compose.yml pull
endef

$(foreach svc,$(SERVICES),$(eval $(call SERVICE_TARGETS,$(svc))))
