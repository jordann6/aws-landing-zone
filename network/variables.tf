variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "network_account_id" {
  description = "Network account id (from the governance root's network_account_id output)"
  type        = string
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
  default     = [".amazonaws.com", ".amazoncognito.com"]
}

variable "flow_log_retention_days" {
  description = "CloudWatch retention for VPC flow logs"
  type        = number
  default     = 14
}

variable "org_arn" {
  description = "Organization ARN to share the TGW with via RAM (from the governance root). Empty skips the share."
  type        = string
  default     = ""
}
