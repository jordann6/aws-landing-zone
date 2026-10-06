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

# Transitional: keeps the CI roles able to read and write the legacy shared
# bucket while state is migrated and open branches rebase. Set both to "" in the
# follow-up change once no branch points at the old backend (ADR-0003).
variable "legacy_state_bucket" {
  description = "Legacy shared state bucket the CI roles keep access to during the migration. Empty drops the grant."
  type        = string
  default     = "tf-state-jordprojs"
}

variable "legacy_state_key_prefix" {
  description = "This repo's key prefix in the legacy shared bucket"
  type        = string
  default     = "aws-scp-governance"
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
