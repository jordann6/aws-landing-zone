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

variable "max_age_hours" {
  description = "Alarm when the newest object in the bucket is older than this"
  type        = number
  default     = 30
}

variable "ia_after_days" {
  type    = number
  default = 30
}

variable "glacier_after_days" {
  type    = number
  default = 90
}

variable "expire_after_days" {
  description = "Expire current objects after this many days. Null keeps them forever (the default for a retained landing bucket)."
  type        = number
  default     = null
}

variable "noncurrent_expire_days" {
  description = "Expire noncurrent versions after this many days. Null keeps them."
  type        = number
  default     = null
}

variable "freshness_alarm_enabled" {
  description = "Alarm when the newest object is older than max_age_hours. Leave false until a producer writes here; cold data would alarm forever."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "heartbeat_enabled" {
  description = "Run the synthetic heartbeat producer. Set false to pause it and prove the stale alarm."
  type        = bool
  default     = true
}

variable "heartbeat_prefix" {
  description = "Prefix the heartbeat producer writes under. Its role can write nowhere else."
  type        = string
  default     = "heartbeat/"
}

variable "heartbeat_every_hours" {
  type    = number
  default = 6
}

variable "heartbeat_expire_days" {
  description = "Expire heartbeat objects after this many days"
  type        = number
  default     = 7
}
