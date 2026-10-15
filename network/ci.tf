# Which member-account role this run assumes (ADR-0004). platform-guardrails
# v1.7.0 exports TF_VAR_ci_stage in every credentialed CI job: plan, apply or
# destroy. It is ephemeral, so it is not frozen into a saved plan, and the gated
# apply job replays the reviewed plan under its own (write) stage. Unset, as on an
# operator's machine, it falls back to OrganizationAccountAccessRole.
#
# This only selects a name. IAM enforces the pairing: the member gha-apply role
# trusts only the environment-gated management gha-apply role.
variable "ci_stage" {
  description = "CI stage set by platform-guardrails (plan, apply, destroy); empty for local runs"
  type        = string
  default     = ""
  ephemeral   = true
}

locals {
  member_role_name = lookup({
    plan    = "gha-plan"
    apply   = "gha-apply"
    destroy = "gha-apply"
  }, var.ci_stage, "OrganizationAccountAccessRole")
}
