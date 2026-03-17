# =============================================================================
# Makefile — Flask API Docker automation
# Usage: make <target>   (run `make help` for a list of targets)
# =============================================================================

IMAGE_NAME     ?= flask-api
IMAGE_TAG      ?= latest
CONTAINER_NAME ?= flask-api-container
HOST_PORT      ?= 5000
DOCKER_HUB_USER ?= $(DOCKER_HUB_USERNAME)

.PHONY: help build build-no-cache run run-dev stop restart \
        logs shell inspect test push push-tag clean prune

# ─── Default target ──────────────────────────────────────────────────────────
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ─── Build ────────────────────────────────────────────────────────────────────
build: ## Build image (uses layer cache)
	docker build --tag $(IMAGE_NAME):$(IMAGE_TAG) .

build-no-cache: ## Build image from scratch (bypasses cache)
	docker build --no-cache --tag $(IMAGE_NAME):$(IMAGE_TAG) .

# ─── Run / Stop ───────────────────────────────────────────────────────────────
run: ## Start container in detached mode
	docker run -d \
		--name $(CONTAINER_NAME) \
		-p $(HOST_PORT):5000 \
		--restart unless-stopped \
		$(IMAGE_NAME):$(IMAGE_TAG)
	@echo "API running → http://localhost:$(HOST_PORT)"

run-dev: ## Start container interactively with source mounted (hot-reload)
	docker run --rm -it \
		--name $(CONTAINER_NAME)-dev \
		-p $(HOST_PORT):5000 \
		-e FLASK_ENV=development \
		-v "$(PWD)/app:/app" \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		flask --app app run --host 0.0.0.0 --reload

stop: ## Stop and remove the container
	docker stop $(CONTAINER_NAME) 2>/dev/null || true
	docker rm   $(CONTAINER_NAME) 2>/dev/null || true

restart: stop run ## Stop, then start the container

# ─── Inspect ─────────────────────────────────────────────────────────────────
logs: ## Tail live container logs
	docker logs -f $(CONTAINER_NAME)

shell: ## Open a shell inside the running container
	docker exec -it $(CONTAINER_NAME) /bin/sh

inspect: ## Print image size and layer breakdown
	@echo "=== Image size ==="
	@docker image inspect $(IMAGE_NAME):$(IMAGE_TAG) \
		--format '{{printf "%.1f MB" (divf .Size 1048576)}}'
	@echo ""
	@echo "=== Layer history ==="
	@docker history $(IMAGE_NAME):$(IMAGE_TAG)

# ─── Test ─────────────────────────────────────────────────────────────────────
test: ## Run the test suite inside a temporary container
	docker run --rm \
		-e FLASK_ENV=testing \
		-v "$(PWD)/app:/app" \
		--entrypoint python \
		$(IMAGE_NAME):$(IMAGE_TAG) \
		-m pytest tests/ -v --tb=short

# ─── Push ─────────────────────────────────────────────────────────────────────
push: ## Push :latest and :<tag> to Docker Hub (set DOCKER_HUB_USERNAME)
	@test -n "$(DOCKER_HUB_USER)" || \
		(echo "ERROR: DOCKER_HUB_USERNAME env var is not set"; exit 1)
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_HUB_USER)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(DOCKER_HUB_USER)/$(IMAGE_NAME):latest
	docker push $(DOCKER_HUB_USER)/$(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(DOCKER_HUB_USER)/$(IMAGE_NAME):latest

push-tag: ## Push a specific tag: make push-tag IMAGE_TAG=v1.2.0
	$(MAKE) push IMAGE_TAG=$(IMAGE_TAG)

# ─── Cleanup ──────────────────────────────────────────────────────────────────
clean: stop ## Remove the local image
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true

prune: ## Remove ALL unused Docker objects (images, containers, volumes, networks)
	docker system prune -f
