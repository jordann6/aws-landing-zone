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

variable "check_url" {
  description = "URL to monitor"
  type        = string
  default     = "https://jordandesigns.io"
  validation {
    condition     = can(regex("^https://", var.check_url))
    error_message = "Monitor an https URL so the certificate check applies."
  }
}

variable "content_check" {
  description = "Substring that must appear in the response body. Empty disables the check."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "ssl_warn_days" {
  description = "Alarm when the certificate has fewer than this many days left"
  type        = number
  default     = 21
}

variable "latency_threshold_ms" {
  type    = number
  default = 3000
}
