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
  default     = "aws-scp-governance"
}

variable "state_bucket" {
  description = "S3 bucket holding this repo's Terraform state (CI roles need access to it)"
  type        = string
  default     = "tf-state-jordprojs"
}

variable "state_key_prefix" {
  description = "Key prefix within the state bucket this repo owns"
  type        = string
  default     = "aws-scp-governance"
}

# The environments that gate the write-scoped apply role. Only OIDC tokens minted
# from a job bound to one of these environments can assume gha-apply, so the
# required reviewer on the environment is the just-in-time-to-prod control.
variable "apply_environments" {
  description = "GitHub environments allowed to assume the write-scoped apply role"
  type        = list(string)
  default     = ["prod-apply", "destroy"]
}
