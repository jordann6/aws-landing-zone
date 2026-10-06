variable "region" {
  type    = string
  default = "us-east-1"
}

variable "owner" {
  type    = string
  default = "jordan"
}

variable "cost_center" {
  type    = string
  default = "cc-0001"
}

variable "forensics_prefix" {
  description = "Name prefix of the forensics stack in the security account (aws-incident-forensics/terraform/lz)"
  type        = string
  default     = "incident-forensics-lz"
}

variable "responder_role_name" {
  description = "Remediation role the incident responder creates in prod (aws-incident-responder/terraform/lz)"
  type        = string
  default     = "incident-responder-lz-remediate"
}

variable "revocable_role_path" {
  description = "Only roles under this path may receive the forensics session-revoke policy"
  type        = string
  default     = "/lz-compute/"
}
