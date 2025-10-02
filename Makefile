.PHONY: help bootstrap clean deploy logs test

GITHUB_USER ?= munichbughunter
IMAGE_REGISTRY = ghcr.io/$(GITHUB_USER)
CLUSTER_NAME = platform-learning

help: ## Zeige diese Hilfe
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

bootstrap: ## Initialisiere lokale Umgebung (Cluster, ArgoCD, Images)
	@./bootstrap.sh

build-all: ## Build all Docker images and push to GHCR
	@echo "Validate GitHub Token..."
	@if [ -z "$$GH_TOKEN" ]; then \
		echo "Error: GH_TOKEN environment variable is not set. Export GH_TOKEN=ghp_..."; \
		exit 1; \
	fi
	@echo "$$GH_TOKEN" | docker login ghcr.io -u $(GITHUB_USER) --password-stdin
	@echo "Building React Frontend..."
	@echo "Building and pushing image the easy way with plain docker commands"
	@docker build -t $(IMAGE_REGISTRY)/frontend:latest ./apps/frontend/
	@docker push $(IMAGE_REGISTRY)/frontend:latest
	@echo "Building Java Backend..."
	@docker build -t $(IMAGE_REGISTRY)/backend-java:latest ./apps/backend-java/
	@docker push $(IMAGE_REGISTRY)/backend-java:latest
	@echo "✓ Images successfully built and pushed"

build-frontend: ## Build React Frontend Docker image and push to GHCR
	@echo "Validate GitHub Token..."
	@if [ -z "$$GH_TOKEN" ]; then \
		echo "Error: GH_TOKEN environment variable is not set. Export GH_TOKEN=ghp_..."; \
		exit 1; \
	fi
	@docker build -t $(IMAGE_REGISTRY)/platform-frontend:latest ./apps/frontend/
	@docker push $(IMAGE_REGISTRY)/platform-frontend:latest
	@echo "✓ Frontend Image pushed"

build-backend-java: ## Build Java Backend Docker image and push to GHCR
	@echo "Validate GitHub Token..."
	@if [ -z "$$GH_TOKEN" ]; then \
		echo "Error: GH_TOKEN environment variable is not set. Export GH_TOKEN=ghp_..."; \
		exit 1; \
	fi
	@docker build -t $(IMAGE_REGISTRY)/backend-java:latest ./apps/backend-java/
	@docker push $(IMAGE_REGISTRY)/backend-java:latest
	@echo "✓ Backend Image pushed"

deploy: ## Synchronize ArgoCD Applications (triggers deployment)
	@echo "Trigger ArcgoCD Hard Refresh..."
	@kubectl patch app frontend-app -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || echo "Frontend App not yet registered"
	@kubectl patch app backend-java-app -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' 2>/dev/null || echo "Backend App not yet registered"
	@echo "✓ ArgoCD Sync triggered"
	@echo ""
	@echo "Check Status with: make status"
	
status: ## Show Status of all Services
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  ArgoCD Applications"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@kubectl get applications -n argocd 2>/dev/null || echo "No ArgoCD Apps found"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Pods in platform-dev"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@kubectl get pods -n platform-dev 2>/dev/null || echo "Namespace platform-dev not found"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Services in platform-dev"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@kubectl get svc -n platform-dev 2>/dev/null || echo "No Services found"
	@echo ""

logs-frontend: ## Show Frontend Logs (follow mode)
	@kubectl logs -n platform-dev -l app=frontend --tail=100 -f

logs-backend: ## Zeige Backend Java Logs (follow mode)
	@kubectl logs -n platform-dev -l app=backend-java --tail=100 -f

test-frontend: ## Execute Frontend Tests
	@cd apps/frontend && npm test -- --run

test-backend: ## Execute Backend Tests
	@cd apps/backend-java && ./mvnw test

test: test-frontend test-backend ## Execute All Tests

clean: ## Delete Cluster Completely
	@echo "⚠  WARNING: This will delete the entire cluster!"
	@read -p "Continue? (y/n) " -n 1 -r; \
	echo ""; \
	if [[ $$REPLY =~ ^[Jj]$$ ]]; then \
		k3d cluster delete $(CLUSTER_NAME); \
		echo "✓ Cluster deleted"; \
	else \
		echo "Abgebrochen"; \
	fi

argocd-ui: ## Port-Forward for ArgoCD UI
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  ArgoCD UI"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "URL:      https://localhost:8081"
	@echo "Username: admin"
	@echo "Password: $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
	@echo ""
	@echo "Starting Port-Forward (Ctrl+C to stop)..."
	@kubectl port-forward svc/argocd-server -n argocd 8081:443

argocd-password: ## Show ArgoCD Admin Password
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d && echo

frontend-ui: ## Port-Forward for Frontend UI
	@echo "Frontend UI: http://localhost:3000"
	@kubectl port-forward svc/frontend -n platform-dev 3000:80

backend-api: ## Port-Forward for Backend API
	@echo "Backend API: http://localhost:8080"
	@kubectl port-forward svc/backend-java -n platform-dev 8080:8080

ghcr-login: ## Login to GitHub Container Registry
	@if [ -z "$$GITHUB_TOKEN" ]; then \
		echo "ERROR: GITHUB_TOKEN not set"; \
		exit 1; \
	fi
	@echo "$$GITHUB_TOKEN" | docker login ghcr.io -u $(GITHUB_USER) --password-stdin
	@echo "✓ Login successful"

cluster-info: ## Show Cluster Information
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "  Cluster Information"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@kubectl cluster-info
	@echo ""
	@kubectl get nodes
	@echo ""
	@echo "Kubeconfig: $$(k3d kubeconfig write $(CLUSTER_NAME) 2>/dev/null || echo 'Cluster not found')"