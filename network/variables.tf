variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "network_account_id" {
  description = "Optional cross-check: when set, it must equal network_account_id in the accounts state, which is the source of truth"
  type        = string
  default     = null
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "jordan"
}

variable "cost_center" {
  description = "CostCenter allocation tag (cc-NNNN)"
  type        = string
  default     = "cc-0001"
}

variable "hub_cidr" {
  description = "Inspection/hub VPC CIDR (platform tier from the address plan)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az" {
  description = "AZ for the demo inspection data path. Production spans all AZs."
  type        = string
  default     = "us-east-1a"
}

variable "allowed_egress_domains" {
  description = "Domains the firewall permits outbound; everything else is denied"
  type        = list(string)
  # The incident responder's summary call (bedrock-runtime) is covered by
  # .amazonaws.com. The bedrock-mantle (api.aws) entry for the old Claude path was
  # removed once the summary moved to an in-region model.
  default = [".amazonaws.com", ".amazoncognito.com"]
}

variable "inspected_spoke_cidrs" {
  description = "Spoke source ranges inspected by the domain allowlist"
  type        = list(string)
  default     = ["10.3.0.0/16"]
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs"
  type        = number
  default     = 14
}

variable "org_arn" {
  description = "Organization ARN to share the TGW with via RAM. null (the default) reads it from the accounts state; an empty string skips the share."
  type        = string
  default     = null
}
