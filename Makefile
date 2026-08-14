.DEFAULT_GOAL := help
SHELL := /bin/bash

KIND_CLUSTER  := lumana-dev
KUBE_CONTEXT  := kind-$(KIND_CLUSTER)
NAMESPACE     := lumana-dev
INGRESS_HOST  := lumana.localtest.me:8080

.PHONY: help
help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- local (compose) ----

.PHONY: local-secrets
local-secrets: ## Generate gitignored .env and local credential files
	@./scripts/bootstrap-local.sh

.PHONY: up
up: local-secrets ## Build and start the Compose stack
	docker compose up --build -d
	@echo "==> waiting for the API to become ready"
	@for i in $$(seq 1 30); do \
		curl -fsS http://localhost:8000/readyz >/dev/null 2>&1 && \
			{ echo "==> ready at http://localhost:8000 (docs at /docs)"; exit 0; }; \
		sleep 2; \
	done; \
	echo "!! API did not become ready; check 'make logs'"; exit 1

.PHONY: down
down: ## Stop the Compose stack and remove volumes
	docker compose down -v

.PHONY: logs
logs: ## Tail Compose logs
	docker compose logs -f

.PHONY: smoke
smoke: ## Exercise the Compose API end to end
	@echo "== /healthz ==" && curl -fsS localhost:8000/healthz && echo
	@echo "== /readyz ==" && curl -fsS localhost:8000/readyz && echo
	@echo "== /rotation ==" && curl -fsS localhost:8000/rotation && echo
	@echo "== /search?q=inception (expect source=upstream) ==" && \
		curl -fsS 'localhost:8000/search?q=inception' | head -c 300 && echo
	@echo "== /search?q=inception again (expect source=cache) ==" && \
		curl -fsS 'localhost:8000/search?q=inception' | head -c 120 && echo
	@echo "== /history ==" && curl -fsS localhost:8000/history | head -c 300 && echo

.PHONY: rotate-local
rotate-local: ## Simulate one rotation against the Compose stack
	@./scripts/rotate-local.sh

# -------------------------------------------------------------------- kind (dev) ----

.PHONY: kind-up
kind-up: ## Create the kind cluster and install ingress-nginx
	kind create cluster --config k8s/kind/cluster.yaml
	@echo "==> installing ingress-nginx"
	helm upgrade --install ingress-nginx ingress-nginx \
		--repo https://kubernetes.github.io/ingress-nginx \
		--namespace ingress-nginx --create-namespace \
		--kube-context $(KUBE_CONTEXT) \
		--set controller.service.type=NodePort \
		--set controller.hostPort.enabled=true \
		--set-string controller.nodeSelector.ingress-ready=true \
		--set controller.admissionWebhooks.enabled=false \
		--wait --timeout 5m

.PHONY: kind-down
kind-down: ## Delete the kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

.PHONY: k8s-secrets
k8s-secrets: local-secrets ## Generate gitignored secret files for the dev overlay
	@./scripts/gen-overlay-secrets.sh

.PHONY: images
images: ## Build both images and load them into kind
	docker build -t lumana/api:dev ./app
	docker build -t lumana/rotator:dev ./rotator
	kind load docker-image lumana/api:dev lumana/rotator:dev --name $(KIND_CLUSTER)

.PHONY: deploy-dev
deploy-dev: k8s-secrets ## Apply the dev overlay to kind
	kustomize build k8s/overlays/dev | kubectl --context $(KUBE_CONTEXT) apply -f -
	kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) rollout status deploy/api --timeout=180s

.PHONY: dev
dev: kind-up images deploy-dev ## Full local pipeline: cluster, images, deploy
	@echo "==> http://$(INGRESS_HOST)"

.PHONY: redeploy
redeploy: images ## Rebuild images and restart the API without recreating the cluster
	kustomize build k8s/overlays/dev | kubectl --context $(KUBE_CONTEXT) apply -f -
	kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) rollout restart deploy/api
	kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) rollout status deploy/api --timeout=180s

.PHONY: status
status: ## Show what is running in the dev namespace
	@kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) get pods,svc,ingress,cronjob

.PHONY: k8s-smoke
k8s-smoke: ## Exercise the API through the kind Ingress
	@echo "== /rotation ==" && curl -fsS http://$(INGRESS_HOST)/rotation && echo
	@echo "== /search?q=matrix ==" && \
		curl -fsS 'http://$(INGRESS_HOST)/search?q=matrix' | head -c 250 && echo
	@echo "== /history ==" && curl -fsS http://$(INGRESS_HOST)/history | head -c 250 && echo

.PHONY: watch-rotation
watch-rotation: ## Live view of the credential rotating every minute
	@echo "Watching the published credential and the app's view of it. Ctrl-C to stop."
	@while true; do \
		printf '%s  secret=%-6s  app=%s\n' \
			"$$(date +%H:%M:%S)" \
			"$$(kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) get secret mongodb-app-credentials -o jsonpath='{.data.username}' | base64 -d)" \
			"$$(curl -fsS http://$(INGRESS_HOST)/rotation 2>/dev/null || echo unreachable)"; \
		sleep 5; \
	done

.PHONY: rotator-logs
rotator-logs: ## Logs from the most recent rotation runs
	@kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) logs -l app.kubernetes.io/name=credential-rotator --tail=50

.PHONY: api-logs
api-logs: ## Follow API logs, filtering out driver noise
	@kubectl --context $(KUBE_CONTEXT) -n $(NAMESPACE) logs -f deploy/api | grep -vE 'pymongo\.(topology|serverSelection)'

# -------------------------------------------------------------------------- proof ----

.PHONY: loadtest
loadtest: ## Prove zero downtime: constant load across 5+ rotations
	k6 run -e BASE_URL=http://$(INGRESS_HOST) load/rotation-test.js

# ---------------------------------------------------------------------- terraform ----

.PHONY: tf-plan
tf-plan: ## Plan the GCP infrastructure
	cd terraform && terraform plan

.PHONY: tf-apply
tf-apply: ## Create the GCP infrastructure
	cd terraform && terraform apply

.PHONY: tf-destroy
tf-destroy: ## Destroy the GCP infrastructure (stops all cloud spend)
	cd terraform && terraform destroy
