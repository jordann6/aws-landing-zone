variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub org/user that owns the repo allowed to assume the CI roles"
  type        = string
  default     = "jordann6"
}

variable "github_repo" {
  description = "Repository allowed to assume the CI roles"
  type        = string
  default     = "aws-landing-zone"
}

variable "state_bucket" {
  description = "Dedicated S3 bucket holding this repo's Terraform state, created by state_backend.tf (ADR-0003). No account id in the name."
  type        = string
  default     = "jordann6-aws-landing-zone-tfstate"
}

variable "state_kms_alias" {
  description = "Alias of the customer-managed key that encrypts the state bucket. Every backend block sets kms_key_id to this alias."
  type        = string
  default     = "alias/aws-landing-zone-tfstate"
}

variable "state_key_prefix" {
  description = "Key prefix within the state bucket this repo owns"
  type        = string
  default     = "aws-landing-zone"
}

# Rollback lever only. The migration finished and every branch points at the
# dedicated backend (2026-10-06), so the CI roles no longer reach the legacy
# shared bucket. Setting tf-state-jordprojs / aws-scp-governance here restores
# the grant if a rollback to the legacy objects is ever needed (ADR-0003).
variable "legacy_state_bucket" {
  description = "Legacy shared state bucket the CI roles may reach. Empty (the default) means no grant."
  type        = string
  default     = ""
}

variable "legacy_state_key_prefix" {
  description = "This repo's key prefix in the legacy shared bucket (used only when legacy_state_bucket is set)"
  type        = string
  default     = ""
}

# The environments that gate the write-scoped apply role. Only OIDC tokens minted
# from a job bound to one of these environments can assume gha-apply, so the
# required reviewer on the environment is the just-in-time-to-prod control.
variable "create_github_oidc_provider" {
  description = "Create the account-global GitHub OIDC provider. Leave false when it already exists in the account (another project owns it); set true in a fresh account."
  type        = bool
  default     = false
}

variable "apply_environments" {
  description = "GitHub environments allowed to assume the write-scoped apply role"
  type        = list(string)
  default     = ["prod-apply", "destroy"]
}
