TF_ACCT ?= accounts
TF_GOV ?= terraform
TF_NET ?= network
TF_WORK ?= workload

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

# ---- static gates (same as CI, credential-free) ----------------------------

.PHONY: fmt
fmt: ## Terraform format check, all roots
	terraform -chdir=$(TF_ACCT) fmt -check -recursive
	terraform -chdir=$(TF_GOV) fmt -check -recursive
	terraform -chdir=$(TF_NET) fmt -check -recursive
	terraform -chdir=$(TF_WORK) fmt -check -recursive

.PHONY: validate
validate: ## Terraform validate, all roots
	terraform -chdir=$(TF_ACCT) init -backend=false && terraform -chdir=$(TF_ACCT) validate
	terraform -chdir=$(TF_GOV) init -backend=false && terraform -chdir=$(TF_GOV) validate
	terraform -chdir=$(TF_NET) init -backend=false && terraform -chdir=$(TF_NET) validate
	terraform -chdir=$(TF_WORK) init -backend=false && terraform -chdir=$(TF_WORK) validate

.PHONY: diagram
diagram: ## Regenerate docs/architecture.png
	python3 docs/diagram.py

# ---- deploy / test / destroy ----------------------------------------------

.PHONY: deploy
deploy: ## Deploy accounts, governance, then the (hourly-billed) network + workload roots
	@echo "==> Accounts root (persistent: org, OUs, member accounts, SCPs). Never destroyed."
	terraform -chdir=$(TF_ACCT) init
	terraform -chdir=$(TF_ACCT) apply
	@echo ""
	@echo "==> Governance root (free tier: logging, detective, identity)"
	terraform -chdir=$(TF_GOV) init
	terraform -chdir=$(TF_GOV) apply
	@echo ""
	@echo "==> Network root plans the HOURLY inspection layer (NAT + Network Firewall)."
	@echo "    Projected demo-window cost is a few dollars; it is torn down by 'make destroy'."
	@NET_ID=$$(terraform -chdir=$(TF_ACCT) output -raw network_account_id); \
	 ORG_ARN=$$(terraform -chdir=$(TF_ACCT) output -raw organization_arn); \
	 terraform -chdir=$(TF_NET) init; \
	 terraform -chdir=$(TF_NET) apply \
	   -var network_account_id=$$NET_ID \
	   -var org_arn=$$ORG_ARN
	@echo ""
	@echo "==> Workload root: prod VPC, RDS Multi-AZ, and EKS (hourly). Torn down by 'make destroy'."
	@PROD_ID=$$(terraform -chdir=$(TF_ACCT) output -raw prod_account_id); \
	 NET_ID=$$(terraform -chdir=$(TF_ACCT) output -raw network_account_id); \
	 TGW_ID=$$(terraform -chdir=$(TF_NET) output -raw transit_gateway_id); \
	 terraform -chdir=$(TF_WORK) init; \
	 terraform -chdir=$(TF_WORK) apply \
	   -var prod_account_id=$$PROD_ID \
	   -var network_account_id=$$NET_ID \
	   -var transit_gateway_id=$$TGW_ID

.PHONY: test
test: ## Prove the guardrails actually deny, not just that apply succeeded
	scripts/validate.sh
	scripts/test-guardrails.sh
	scripts/test-data-tier.sh

.PHONY: destroy
# The accounts/ root is deliberately absent: member accounts stay ACTIVE across
# teardowns (prevent_destroy, close_on_deletion = false), so a redeploy reuses
# them instead of colliding with SUSPENDED ones.
destroy: ## Tear down everything except the persistent accounts, then verify
	@echo "==> Destroying the workload root first (releases RDS, EKS, endpoints)"
	@echo "    If backups have run, Vault Lock recovery points may block the vault until"
	@echo "    the changeable window; delete recovery points or wait, then re-run."
	-@PROD_ID=$$(terraform -chdir=$(TF_ACCT) output -raw prod_account_id); \
	  NET_ID=$$(terraform -chdir=$(TF_ACCT) output -raw network_account_id); \
	  TGW_ID=$$(terraform -chdir=$(TF_NET) output -raw transit_gateway_id); \
	  terraform -chdir=$(TF_WORK) destroy \
	    -var prod_account_id=$$PROD_ID \
	    -var network_account_id=$$NET_ID \
	    -var transit_gateway_id=$$TGW_ID
	@echo "==> Destroying the network root (releases NAT + Network Firewall)"
	-@NET_ID=$$(terraform -chdir=$(TF_ACCT) output -raw network_account_id); \
	  ORG_ARN=$$(terraform -chdir=$(TF_ACCT) output -raw organization_arn); \
	  terraform -chdir=$(TF_NET) destroy \
	    -var network_account_id=$$NET_ID \
	    -var org_arn=$$ORG_ARN
	@echo "==> Emptying Object-Lock (GOVERNANCE) log buckets with a retention bypass"
	scripts/empty-locked-buckets.sh
	@echo "==> Destroying the governance root"
	terraform -chdir=$(TF_GOV) destroy
	@echo "==> Verifying teardown"
	scripts/verify-teardown.sh
