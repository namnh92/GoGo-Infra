SHELL := /bin/bash
ENV ?= dev
TF_DIR := terraform/environments/$(ENV)

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
	terraform -chdir=$(TF_DIR) plan -input=false

.PHONY: apply
apply: ## terraform apply for $(ENV) — prefer the CI workflow for prod
	terraform -chdir=$(TF_DIR) apply -input=false

.PHONY: check
check: fmt-check validate lint scan ## Everything CI runs before plan

.PHONY: secrets-list
secrets-list: ## List SSM parameter names for $(ENV) (names only, no values)
	./scripts/secrets/list.sh $(ENV)

.PHONY: secrets-validate
secrets-validate: ## Diff SSM against secrets.manifest.yaml for $(ENV)
	./scripts/secrets/validate.sh $(ENV)

.PHONY: secrets-pull
secrets-pull: ## Write .env.runtime (0600) from SSM for $(ENV)
	./scripts/secrets/pull.sh $(ENV)
