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
variable "scanner_account_id" {
  description = "Scanner's home account. Defaults to the existing management-account scanner."
  type        = string
  default     = null
  validation {
    condition     = var.scanner_account_id == null ? true : can(regex("^[0-9]{12}$", var.scanner_account_id))
    error_message = "scanner_account_id must be a twelve-digit account ID."
  }
}
variable "scanner_prefix" {
  type    = string
  default = "secops"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.scanner_prefix))
    error_message = "Use a short lowercase IAM role prefix."
  }
}
