variable "region" {
  description = "Primary region"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "Backup copy (DR) region for cross-region backup"
  type        = string
  default     = "us-west-2"
}

variable "enable_cross_region_backup" {
  description = "Create DR backup resources only after the destination region is approved by organization governance. Deferred to Phase D."
  type        = bool
  default     = false
}

variable "owner" {
  type    = string
  default = "jordan"
}

variable "cost_center" {
  type    = string
  default = "cc-0001"
}

# Wired from the governance and network root outputs by make deploy.
variable "prod_account_id" {
  description = "Prod workload account id (governance output prod_account_id)"
  type        = string
}

variable "network_account_id" {
  description = "Network account id (governance output network_account_id)"
  type        = string
}

variable "transit_gateway_id" {
  description = "Hub Transit Gateway id (network output transit_gateway_id)"
  type        = string
}

variable "prod_cidr" {
  description = "Prod workload VPC CIDR (from the address plan)"
  type        = string
  default     = "10.3.0.0/16"
}

variable "azs" {
  description = "AZs for the prod VPC (two for Multi-AZ)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16.14"
}

variable "db_instance_class" {
  description = "RDS instance class (small, timed)"
  type        = string
  default     = "db.t3.small"
}

variable "backup_min_retention_days" {
  description = "Vault Lock minimum retention (WORM floor)"
  type        = number
  default     = 7
}

variable "backup_max_retention_days" {
  description = "Vault Lock maximum retention"
  type        = number
  default     = 30
}

variable "backup_changeable_after_days" {
  description = "Compliance-mode Vault Lock grace period in days. Finish demo teardown before it expires; retained recovery points become immutable afterward."
  type        = number
  default     = 3
}

variable "eks_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.35"
}

variable "eks_node_instance_type" {
  description = "EKS managed node group instance type"
  type        = string
  default     = "t3.medium"
}

variable "upstream_registries" {
  description = "Public registries fronted by an ECR pull-through cache (the only sanctioned pull path)"
  type        = map(string)
  default = {
    "ecr-public" = "public.ecr.aws"
    "quay"       = "quay.io"
  }
}
