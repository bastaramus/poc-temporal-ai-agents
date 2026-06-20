.DEFAULT_GOAL := help
SHELL := /bin/bash

NS         ?= agent-poc
KEYCLOAK   ?= http://localhost:8080
PUBLIC_API ?= http://localhost:8081
INTERNAL_API ?= http://localhost:8082

# Container engine: prefer podman (rootful machine works on macOS without
# Docker Desktop); fall back to docker. Override with CONTAINER_ENGINE=docker.
CONTAINER_ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || (command -v docker >/dev/null 2>&1 && echo docker))

# ── Colours ────────────────────────────────────────────────────────────
BOLD := $(shell tput bold 2>/dev/null)
RST  := $(shell tput sgr0 2>/dev/null)

# ── Help ───────────────────────────────────────────────────────────────
help: ## show this help
	@echo "$(BOLD)Targets$(RST)"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-22s %s\n", $$1, $$2}'

# ── Cluster lifecycle ──────────────────────────────────────────────────
bootstrap: ## one-time container engine + minikube cluster (podman preferred, docker fallback)
	./scripts/bootstrap-cluster.sh

up: ## resume an existing minikube + container engine
	@if command -v podman >/dev/null 2>&1; then podman machine start || true; fi
	minikube start

down: ## stop minikube and the container VM (preserves state)
	minikube stop || true
	@if command -v podman >/dev/null 2>&1; then podman machine stop || true; fi

nuke: ## delete the cluster (next install needs `make bootstrap`)
	minikube delete || true

status: ## show cluster + container engine status
	@if command -v podman >/dev/null 2>&1; then echo "── podman machine ──"; podman machine list || true; fi
	@if command -v docker >/dev/null 2>&1; then echo "── docker ──"; docker info --format '{{.ServerVersion}} ({{.OperatingSystem}})' 2>/dev/null || echo "docker daemon unreachable"; fi
	@echo "── minikube ──";       minikube status || true
	@echo "── pods ──";           kubectl -n $(NS) get pods 2>/dev/null || true

# ── Build / deploy ─────────────────────────────────────────────────────
install: ## build images, push to cluster, helmfile apply
	./scripts/install.sh

install-no-build: ## install but skip image build (reuse existing images)
	./scripts/install.sh --skip-build

install-no-load: ## install but skip pushing images into the cluster
	./scripts/install.sh --skip-load

install-helm-only: ## skip build AND push — only re-apply ConfigMaps + helmfile
	./scripts/install.sh --skip-build --skip-load

install-build-only: ## only build + push images, skip helmfile apply
	./scripts/install.sh --skip-helm

build: ## build images (podman if installed, else docker), then `minikube image load`
	@test -n "$(CONTAINER_ENGINE)" || { echo "Neither podman nor docker found. brew install podman or install Docker Desktop." >&2; exit 1; }
	@ARCH=$$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo amd64); \
	  PLAT=linux/$$ARCH; echo "engine: $(CONTAINER_ENGINE)  platform: $$PLAT"; \
	  $(CONTAINER_ENGINE) build --platform $$PLAT -t poc/public-api-server:dev   services/public-api-server && \
	  $(CONTAINER_ENGINE) build --platform $$PLAT -t poc/internal-api-server:dev services/internal-api-server && \
	  $(CONTAINER_ENGINE) build --platform $$PLAT -t poc/worker:dev              temporal/worker && \
	  $(CONTAINER_ENGINE) save poc/public-api-server:dev   | minikube image load - && \
	  $(CONTAINER_ENGINE) save poc/internal-api-server:dev | minikube image load - && \
	  $(CONTAINER_ENGINE) save poc/worker:dev              | minikube image load -

apply: ## helmfile apply only (no rebuild)
	helmfile apply --skip-diff-on-install

destroy: ## helmfile destroy — tear down releases, keep cluster
	helmfile destroy

# ── Day-2 ──────────────────────────────────────────────────────────────
pf: port-forward
port-forward: ## kubectl port-forward Keycloak / public-api / internal-api / Temporal UI
	./scripts/port-forward.sh

k9s: ## launch k9s scoped to the PoC namespace
	k9s -n $(NS)

logs-public: ## tail public-api-server logs
	kubectl -n $(NS) logs -f deploy/public-api-server

logs-internal: ## tail internal-api-server logs
	kubectl -n $(NS) logs -f deploy/internal-api-server

logs-worker: ## tail Temporal worker logs
	kubectl -n $(NS) logs -f deploy/worker

logs-keycloak: ## tail Keycloak logs
	kubectl -n $(NS) logs -f sts/keycloak

restart: ## rolling-restart the three services (keep config + DB)
	kubectl -n $(NS) rollout restart deploy/public-api-server
	kubectl -n $(NS) rollout restart deploy/internal-api-server
	kubectl -n $(NS) rollout restart deploy/worker

reimport-realm: ## drop+recreate keycloak DB so realm-export.json is re-applied
	./scripts/reimport-realm.sh

# ── Tokens ─────────────────────────────────────────────────────────────
token-alice: ## print Alice's JWT (tenant-a)
	@./scripts/get-token-alice.sh

token-bob: ## print Bob's JWT (tenant-b)
	@./scripts/get-token-bob.sh

# ── Curl flows ─────────────────────────────────────────────────────────
# Examples:
#   make write-alice TITLE=hello CONTENT="tenant-a secret"
#   make read-alice  DOC=<uuid>
TITLE   ?= hello
CONTENT ?= tenant-a secret
DOC     ?=

write-alice: ## start-check write as Alice (TITLE=, CONTENT=)
	@JWT=$$(./scripts/get-token-alice.sh); \
	  ./scripts/start-check.sh "$$JWT" write "$(TITLE)" "$(CONTENT)"

write-bob: ## start-check write as Bob (TITLE=, CONTENT=)
	@JWT=$$(./scripts/get-token-bob.sh); \
	  ./scripts/start-check.sh "$$JWT" write "$(TITLE)" "$(CONTENT)"

read-alice: ## start-check read as Alice (DOC=<uuid>)
	@test -n "$(DOC)" || (echo "DOC=<uuid> required" >&2; exit 1)
	@JWT=$$(./scripts/get-token-alice.sh); \
	  ./scripts/start-check.sh "$$JWT" read "$(DOC)"

read-bob: ## start-check read as Bob (DOC=<uuid>)
	@test -n "$(DOC)" || (echo "DOC=<uuid> required" >&2; exit 1)
	@JWT=$$(./scripts/get-token-bob.sh); \
	  ./scripts/start-check.sh "$$JWT" read "$(DOC)"

# ── Tests ──────────────────────────────────────────────────────────────
test: deny-test ## alias for the cross-tenant denial assertion suite

deny-test: ## run the four cross-tenant denial assertions
	./scripts/cross-tenant-deny-test.sh

# ── Quality of life ────────────────────────────────────────────────────
psql: ## open psql against the in-cluster Postgres as app_runtime
	kubectl -n $(NS) exec -it sts/postgresql -- \
	  env PGPASSWORD=change-me-runtime psql -U app_runtime -d poc

psql-owner: ## open psql as app_owner (DDL / migrations)
	kubectl -n $(NS) exec -it sts/postgresql -- \
	  env PGPASSWORD=change-me-owner psql -U app_owner -d poc

audit-tail: ## tail the audit_log table for tenant-a
	kubectl -n $(NS) exec -it sts/postgresql -- \
	  env PGPASSWORD=change-me-runtime psql -U app_runtime -d poc -c \
	  "BEGIN; SELECT set_config('app.tenant_id','11111111-1111-1111-1111-111111111111',true); \
	   SELECT created_at, actor, action, decision, reason FROM audit_log ORDER BY created_at DESC LIMIT 20; COMMIT;"

temporal-ui: ## open Temporal Web UI in the browser (requires `make pf`)
	open http://localhost:8088 || xdg-open http://localhost:8088 || true

clean-images: ## remove poc/* images from the cluster and the local container engine
	-minikube image rm poc/public-api-server:dev poc/internal-api-server:dev poc/worker:dev
	@if [ -n "$(CONTAINER_ENGINE)" ]; then \
	  $(CONTAINER_ENGINE) image rm -f poc/public-api-server:dev poc/internal-api-server:dev poc/worker:dev || true; \
	fi

.PHONY: help bootstrap up down nuke status install install-no-build install-no-load \
        install-helm-only install-build-only build apply destroy \
        pf port-forward k9s logs-public logs-internal logs-worker logs-keycloak \
        restart reimport-realm \
        token-alice token-bob write-alice write-bob read-alice read-bob \
        test deny-test psql psql-owner audit-tail temporal-ui clean-images
