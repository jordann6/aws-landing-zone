variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
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

variable "alert_email" {
  description = "Optional email subscribed to both the security-findings and ops topics. Null skips the subscriptions. Set in terraform.tfvars (gitignored)."
  type        = string
  default     = null
}

# --- Names of the monitored resources (set by the network/ and workload/ roots) ---

variable "rds_instance_id" {
  description = "Prod RDS instance identifier (workload/rds.tf)"
  type        = string
  default     = "prod-postgres"
}

variable "eks_cluster_name" {
  description = "Prod EKS cluster name (workload/eks.tf)"
  type        = string
  default     = "prod"
}

variable "firewall_name" {
  description = "Network Firewall name (network/firewall.tf)"
  type        = string
  default     = "inspection-firewall"
}

variable "firewall_az" {
  description = "AZ of the firewall endpoint (network var.az). DroppedPackets is published per AZ."
  type        = string
  default     = "us-east-1a"
}

variable "backup_vault_name" {
  description = "Prod AWS Backup vault (workload/backup.tf)"
  type        = string
  default     = "prod-data-vault"
}

# --- Alarm thresholds ---

variable "rds_cpu_threshold" {
  description = "RDS CPU percent that raises the alarm (average over 3 x 5 minutes)"
  type        = number
  default     = 80
}

variable "rds_free_storage_threshold_gb" {
  description = "RDS free storage in GB below which the alarm fires"
  type        = number
  default     = 5
}

variable "firewall_dropped_packets_threshold" {
  description = "Dropped packets per 5 minutes above which the firewall alarm fires"
  type        = number
  default     = 100
}

# --- Incident tooling ---

variable "responder_role_name" {
  description = "Remediation role the incident responder creates in prod; it may publish incident notices to the ops topic"
  type        = string
  default     = "incident-responder-lz-remediate"
}

variable "enable_forensics_drill" {
  description = "Create the forensics-drill EventBridge rule (proof sessions only)"
  type        = bool
  default     = false
}
