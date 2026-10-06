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

variable "workloads_allowed_images_state" {
  description = "Allowed AMIs mode for the Workloads OU declarative policy. audit_mode reports ImageAllowed without blocking; switch to enabled once the EKS node and golden AMIs are proven allowed."
  type        = string
  default     = "audit_mode"

  validation {
    condition     = contains(["audit_mode", "enabled"], var.workloads_allowed_images_state)
    error_message = "workloads_allowed_images_state must be audit_mode or enabled."
  }
}
