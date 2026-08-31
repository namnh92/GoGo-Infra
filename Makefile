SHELL := /bin/bash
ENV ?= dev
TF_DIR := terraform/environments/$(ENV)
TF_VARS := -var-file=../../../config/global.tfvars -var-file=../../../config/$(ENV).tfvars

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z0-9_.-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  ENV defaults to 'dev'. Example: make plan ENV=prod"

.PHONY: init
init: ## terraform init for $(ENV)
	terraform -chdir=$(TF_DIR) init

.PHONY: fmt
fmt: ## Rewrite all Terraform files to canonical format
	terraform fmt -recursive .

.PHONY: fmt-check
fmt-check: ## Fail if any Terraform file is not formatted
	terraform fmt -check -recursive .

.PHONY: validate
validate: ## terraform validate for $(ENV)
	terraform -chdir=$(TF_DIR) validate

.PHONY: lint
lint: ## Run tflint across modules and environments
	tflint --recursive

.PHONY: scan
scan: ## Run gitleaks over the working tree
	gitleaks detect --source . --config .gitleaks.toml --redact --verbose

.PHONY: plan
plan: ## terraform plan for $(ENV)
	terraform -chdir=$(TF_DIR) plan -input=false $(TF_VARS)

.PHONY: apply
apply: ## terraform apply for $(ENV) — prefer the CI workflow for prod
	terraform -chdir=$(TF_DIR) apply -input=false $(TF_VARS)

.PHONY: test
test: ## Run the shell unit tests
	./scripts/lib/config.test.sh
	./scripts/ci/check-workflow-auth.test.sh
	./scripts/ci/gitleaks-rules.test.sh
	./scripts/ops/check-quotas.test.sh

.PHONY: check-workflow-auth
check-workflow-auth: ## Assert CI authenticates as a machine, never as a person (INF-024)
	./scripts/ci/check-workflow-auth.sh

.PHONY: check
check: fmt-check validate lint scan test check-workflow-auth ## Everything CI runs before plan

.PHONY: cf-scopes
cf-scopes: ## Probe what the Cloudflare CI tokens can reach for $(ENV)
	./scripts/ops/check-cf-token-scopes.sh $(ENV)

.PHONY: provider-keys
provider-keys: ## Call each Google API with the key $(ENV) actually deploys (INF-052)
	./scripts/ops/check-provider-keys.sh $(ENV)

.PHONY: secrets-list
secrets-list: ## List SSM parameter names for $(ENV) (names only, no values)
	./scripts/secrets/list.sh $(ENV)

.PHONY: secrets-validate
secrets-validate: ## Diff SSM against secrets.manifest.yaml for $(ENV)
	./scripts/secrets/validate.sh $(ENV)

.PHONY: secrets-pull
secrets-pull: ## Write .env.runtime (0600) from SSM for $(ENV)
	./scripts/secrets/pull.sh $(ENV)
