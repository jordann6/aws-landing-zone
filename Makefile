TF_ACCT ?= accounts
TF_GOV ?= terraform
TF_NET ?= network
TF_WORK ?= workload
TF_OBS ?= observability
TF_COMP ?= compute
TF_SEC ?= secrets
TF_INC ?= incident

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  %-22s %s\n", $$1, $$2}'

# ---- static gates (same as CI, credential-free) ----------------------------

.PHONY: fmt
fmt: ## Terraform format check, all roots
	terraform -chdir=$(TF_ACCT) fmt -check -recursive
	terraform -chdir=$(TF_GOV) fmt -check -recursive
	terraform -chdir=$(TF_NET) fmt -check -recursive
	terraform -chdir=$(TF_WORK) fmt -check -recursive
	terraform -chdir=$(TF_OBS) fmt -check -recursive
	terraform -chdir=$(TF_COMP) fmt -check -recursive
	terraform -chdir=$(TF_SEC) fmt -check -recursive
	terraform -chdir=$(TF_INC) fmt -check -recursive

.PHONY: validate
validate: ## Terraform validate, all roots
	terraform -chdir=$(TF_ACCT) init -backend=false && terraform -chdir=$(TF_ACCT) validate
	terraform -chdir=$(TF_GOV) init -backend=false && terraform -chdir=$(TF_GOV) validate
	terraform -chdir=$(TF_NET) init -backend=false && terraform -chdir=$(TF_NET) validate
	terraform -chdir=$(TF_WORK) init -backend=false && terraform -chdir=$(TF_WORK) validate
	terraform -chdir=$(TF_OBS) init -backend=false && terraform -chdir=$(TF_OBS) validate
	terraform -chdir=$(TF_COMP) init -backend=false && terraform -chdir=$(TF_COMP) validate
	terraform -chdir=$(TF_SEC) init -backend=false && terraform -chdir=$(TF_SEC) validate
	terraform -chdir=$(TF_INC) init -backend=false && terraform -chdir=$(TF_INC) validate

.PHONY: diagram
diagram: ## Regenerate docs/architecture.png
	python3 docs/diagram.py

# ---- deploy / test / destroy ----------------------------------------------

.PHONY: deploy
deploy: ## Deploy accounts, governance, network + workload (hourly), observability, golden AMI, management instance
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
	@echo "==> Workload root: prod VPC, RDS Multi-AZ, EKS (hourly), EC2 defaults, golden image pipeline."
	@PROD_ID=$$(terraform -chdir=$(TF_ACCT) output -raw prod_account_id); \
	 NET_ID=$$(terraform -chdir=$(TF_ACCT) output -raw network_account_id); \
	 ORG_ARN=$$(terraform -chdir=$(TF_ACCT) output -raw organization_arn); \
	 TGW_ID=$$(terraform -chdir=$(TF_NET) output -raw transit_gateway_id); \
	 terraform -chdir=$(TF_WORK) init; \
	 terraform -chdir=$(TF_WORK) apply \
	   -var prod_account_id=$$PROD_ID \
	   -var network_account_id=$$NET_ID \
	   -var transit_gateway_id=$$TGW_ID \
	   -var organization_arn=$$ORG_ARN
	@$(MAKE) --no-print-directory deploy-observability
	@$(MAKE) --no-print-directory build-image
	@$(MAKE) --no-print-directory deploy-compute

.PHONY: deploy-observability
deploy-observability: ## Finding routing, OAM monitoring account, central alarms (~free)
	@echo "==> Observability root: security-findings + ops topics, OAM sink and links, alarms"
	terraform -chdir=$(TF_OBS) init
	terraform -chdir=$(TF_OBS) apply

.PHONY: test-observability
test-observability: ## Sample GuardDuty finding, cross-account metrics, forced alarm
	scripts/test-observability.sh

# ---- compute baseline -------------------------------------------------------

.PHONY: stage-role
stage-role: ## Package cis_baseline at its pinned tag and upload it for the image build
	scripts/stage-role.sh

.PHONY: build-image
build-image: ## Bake + test the golden AMI once (~30-45 min, two t3.small)
	scripts/build-image.sh

.PHONY: deploy-compute
deploy-compute: ## Hardened management instance from the newest golden AMI (t3.micro)
	terraform -chdir=$(TF_COMP) init
	terraform -chdir=$(TF_COMP) apply

.PHONY: test-compute
test-compute: ## Prove the baseline on the live instance (defaults, posture, guest checks, patching)
	scripts/test-compute.sh

.PHONY: destroy-compute
destroy-compute: ## Remove the management instance, then every golden AMI and snapshot
	-terraform -chdir=$(TF_COMP) destroy
	scripts/clean-images.sh

# ---- incident tooling ------------------------------------------------------------

.PHONY: clean-forensics
clean-forensics: ## Delete the forensics runbook's prod snapshots (after evidence review)
	scripts/clean-forensics.sh

.PHONY: test
test: ## Prove the guardrails actually deny, not just that apply succeeded
	scripts/validate.sh
	scripts/test-guardrails.sh
	scripts/test-data-tier.sh
	scripts/test-observability.sh
	scripts/test-compute.sh

.PHONY: destroy
# The accounts/ root is deliberately absent: member accounts stay ACTIVE across
# teardowns (prevent_destroy, close_on_deletion = false), so a redeploy reuses
# them instead of colliding with SUSPENDED ones.
destroy: ## Tear down everything except the persistent accounts, then verify
	@echo "==> Deleting forensics snapshots (not in any state)"
	-@$(MAKE) --no-print-directory clean-forensics
	@echo "==> Destroying the compute root and golden AMIs (before the EBS key goes)"
	-@$(MAKE) --no-print-directory destroy-compute
	@echo "==> Destroying the observability root (alarms, OAM, finding routing)"
	-terraform -chdir=$(TF_OBS) destroy
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
