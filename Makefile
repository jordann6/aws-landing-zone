TF_GOV ?= terraform
TF_NET ?= network

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

# ---- static gates (same as CI, credential-free) ----------------------------

.PHONY: fmt
fmt: ## Terraform format check, both roots
	terraform -chdir=$(TF_GOV) fmt -check -recursive
	terraform -chdir=$(TF_NET) fmt -check -recursive

.PHONY: validate
validate: ## Terraform validate, both roots
	terraform -chdir=$(TF_GOV) init -backend=false && terraform -chdir=$(TF_GOV) validate
	terraform -chdir=$(TF_NET) init -backend=false && terraform -chdir=$(TF_NET) validate

.PHONY: diagram
diagram: ## Regenerate docs/architecture.png
	python3 docs/diagram.py

# ---- deploy / test / destroy ----------------------------------------------

.PHONY: deploy
deploy: ## Deploy governance, then the (hourly-billed) network root
	@echo "==> Governance root (free tier: org, guardrails, logging, detective, identity)"
	terraform -chdir=$(TF_GOV) init
	terraform -chdir=$(TF_GOV) apply
	@echo ""
	@echo "==> Network root plans the HOURLY inspection layer (NAT + Network Firewall)."
	@echo "    Projected demo-window cost is a few dollars; it is torn down by 'make destroy'."
	@NET_ID=$$(terraform -chdir=$(TF_GOV) output -raw network_account_id); \
	 ORG_ARN=$$(terraform -chdir=$(TF_GOV) output -raw organization_arn); \
	 terraform -chdir=$(TF_NET) init; \
	 terraform -chdir=$(TF_NET) apply \
	   -var network_account_id=$$NET_ID \
	   -var org_arn=$$ORG_ARN

.PHONY: test
test: ## Prove the guardrails actually deny, not just that apply succeeded
	scripts/validate.sh
	scripts/test-guardrails.sh

.PHONY: destroy
destroy: ## Tear everything down, then verify nothing hourly survives
	@echo "==> Destroying the network root first (releases NAT + Network Firewall)"
	-@NET_ID=$$(terraform -chdir=$(TF_GOV) output -raw network_account_id); \
	  ORG_ARN=$$(terraform -chdir=$(TF_GOV) output -raw organization_arn); \
	  terraform -chdir=$(TF_NET) destroy \
	    -var network_account_id=$$NET_ID \
	    -var org_arn=$$ORG_ARN
	@echo "==> Emptying Object-Lock (GOVERNANCE) log buckets with a retention bypass"
	scripts/empty-locked-buckets.sh
	@echo "==> Destroying the governance root"
	terraform -chdir=$(TF_GOV) destroy
	@echo "==> Verifying teardown"
	scripts/verify-teardown.sh
