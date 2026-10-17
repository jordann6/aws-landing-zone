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

variable "monitored_instance_ids" {
  description = "Instances that get a high-CPU alarm wired to the remediation Lambda. They must also carry the tag Monitored=true."
  type        = set(string)
  default     = []
}

variable "alert_email" {
  description = "Email subscribed to the remediation and on-call topics. Null skips the subscriptions. Set in terraform.tfvars (gitignored)."
  type        = string
  default     = null
}

variable "cpu_threshold" {
  type    = number
  default = 80
}

variable "dry_run" {
  description = "Log and notify without rebooting. Start true, flip after the first alarm drill."
  type        = bool
  default     = true
}

variable "cooldown_seconds" {
  type    = number
  default = 900
}

variable "circuit_window_seconds" {
  type    = number
  default = 3600
}

variable "max_attempts" {
  type    = number
  default = 3
}

variable "log_retention_days" {
  type    = number
  default = 30
}
