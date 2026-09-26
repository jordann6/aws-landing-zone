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
  description = "Owner tag applied fleet-wide via provider default_tags"
  type        = string
  default     = "jordan"
}

variable "cost_center" {
  description = "CostCenter allocation tag (format cc-NNNN, enforced by the FinOps policy)"
  type        = string
  default     = "cc-0001"
}

variable "budget_notification_email" {
  description = "Email that receives budget and cost-anomaly alerts. Set in terraform.tfvars (gitignored)."
  type        = string
}

variable "monthly_budget_limit" {
  description = "Monthly org cost budget in USD that triggers an alert"
  type        = string
  default     = "20"
}

variable "cost_anomaly_threshold" {
  description = "USD impact above which a cost anomaly raises an alert"
  type        = string
  default     = "10"
}

variable "trail_name" {
  description = "Name of the organization CloudTrail"
  type        = string
  default     = "org-trail"
}

variable "trail_lock_retention_days" {
  description = "Object Lock (GOVERNANCE) retention on the trail bucket, in days"
  type        = number
  default     = 1
}

variable "enable_identity_center" {
  description = "Create the Identity Center personas. Requires IAM Identity Center enabled in the org first."
  type        = bool
  default     = true
}

# --- Reduced-footprint toggles -----------------------------------------------
# The canonical landing zone deploys all of these (defaults true). In an org that
# is at its account-count limit or already runs a shared Security Hub / cost
# anomaly monitor, set the relevant flag false in terraform.tfvars to deploy the
# governance core without the piece that cannot be created there.

variable "full_account_set" {
  description = "Create dev/test/prod/network/shared-services member accounts. Set false when the org has no account headroom; only security/log-archive/sandbox are created."
  type        = bool
  default     = true
}

variable "enable_securityhub" {
  description = "Enable Security Hub (org admin, CIS 1.4.0). Set false where Security Hub is already enabled in the security account and managed elsewhere."
  type        = bool
  default     = true
}

variable "enable_cost_anomaly_monitor" {
  description = "Create the Cost Explorer dimensional anomaly monitor. Set false where a SERVICE-dimension monitor already exists in the account (AWS allows only one)."
  type        = bool
  default     = true
}

variable "enable_tag_policy" {
  description = "Attach the organization tag policy. Requires the TAG_POLICY type enabled on the org."
  type        = bool
  default     = true
}
