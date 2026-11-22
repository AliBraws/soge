SHELL := /bin/bash
.DEFAULT_GOAL := help
# Default target: the local stack, as seen from the tools container.
TARGET ?= https://api:8443
INSECURE ?= $(if $(findstring api:8443,$(TARGET)),1,0)
# Only Docker is needed on the workstation: tests and checks run in containers
# pinned to the CI versions (Go 1.27, Python 3.14, curl with OpenSSL).
TOOLS := docker compose --profile tools run --rm -T -e TARGET=$(TARGET) -e INSECURE=$(INSECURE) tools

help: ## list targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-16s %s\n", $$1, $$2}'

doctor: ## check tools, temporary AWS session, region, quotas, DNS delegation (HOSTED_ZONE_ID=Z...)
	./scripts/doctor.sh

env: ## generate local-only secrets into .env (gitignored)
	@test -f .env || { umask 077; printf 'LOCAL_DB_PASSWORD=%s\nLOCAL_QUOTE_KEY=%s\n' "$$(openssl rand -hex 24)" "$$(openssl rand -hex 32)" > .env; echo ".env created"; }

up: env ## run locally: https://localhost:8443 (postgres + migration + API/UI, TLS 1.3)
	docker compose up --build -d --wait
	@echo "https://localhost:8443 (self-signed certificate, accept it in the browser)"

down: ## stop the local stack and delete its data
	docker compose down -v

logs: ## follow the API logs
	docker compose logs -f api

test: ## unit tests in containers (Go 1.27 with race detector, Python 3.14)
	docker run --rm -v "$(CURDIR)/app/api:/src" -w /src -e GOFLAGS=-mod=readonly golang:1.27 \
	  sh -c 'go mod verify && go vet ./... && go test -race -count=1 ./...'
	docker run --rm -v "$(CURDIR)/app/functions:/src:ro" -w /src -e PYTHONDONTWRITEBYTECODE=1 python:3.14-slim \
	  python -m unittest discover -s tests

outage: ## failure drill: database down -> quotes 200, deals 503 + Retry-After, then exactly-once
	./scripts/outage.sh

smoke: ## end-to-end checks (TLS 1.2 refused, idempotency...) against TARGET (default: local stack)
	$(TOOLS) /scripts/smoke.sh

lint: ## same static checks as CI
	gitleaks git --redact --no-banner
	terraform fmt -check -recursive infra
	for d in infra/bootstrap infra/platform; do (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate); done
	tflint --init --config $(CURDIR)/.tflint.hcl && tflint --recursive --config $(CURDIR)/.tflint.hcl
	trivy config --severity HIGH,CRITICAL --exit-code 1 infra
	trivy fs --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 app
	hadolint app/api/Dockerfile

image: ## multi-arch build (amd64 + arm64, no QEMU) + local vulnerability scan
	docker buildx build --platform linux/amd64,linux/arm64 -t soge/api:local app/api
	docker buildx build --platform linux/$$(docker version -f '{{.Server.Arch}}') --load -t soge/api:scan app/api
	trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 soge/api:scan

load-local: ## short k6 run against the local stack
	k6 run --insecure-skip-tls-verify -e TARGET=$(TARGET) -e PEAK_RPS=50 loadtest/k6.js

bootstrap: ## one-time: state bucket, KMS, OIDC, CI roles, ECR (temporary admin session: aws login or CloudShell)
	cd infra/bootstrap && terraform init && terraform apply

plan: ## terraform plan of infra/platform from your laptop (SSO), same inputs as CI
	cd infra/platform && terraform init -input=false -backend-config=../../backend.platform.hcl && terraform plan
