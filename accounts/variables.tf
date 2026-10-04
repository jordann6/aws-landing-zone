variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "org_email_domain" {
  description = "Email address base for member accounts (uses + aliases)"
  type        = string
}

variable "allowed_regions" {
  description = "Regions permitted by the region-lockdown SCP"
  type        = list(string)
  default     = ["us-east-1"]
}

variable "owner" {
  description = "Owner tag applied via provider default_tags"
  type        = string
  default     = "jordan"
}

variable "cost_center" {
  description = "CostCenter allocation tag (format cc-NNNN, enforced by the FinOps policy)"
  type        = string
  default     = "cc-0001"
}

variable "full_account_set" {
  description = "Create dev/test/prod/network/shared-services member accounts. Set false when the org has no account headroom; only security/log-archive/sandbox are created."
  type        = bool
  default     = true
}

variable "enable_tag_policy" {
  description = "Attach the organization tag policy. Requires the TAG_POLICY type enabled on the org."
  type        = bool
  default     = true
}
