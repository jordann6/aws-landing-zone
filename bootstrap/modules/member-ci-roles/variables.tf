variable "plan_principal_arn" {
  description = "Management-account role allowed to assume this account's read-only gha-plan role"
  type        = string
}

variable "apply_principal_arn" {
  description = "Management-account role allowed to assume this account's write gha-apply role"
  type        = string
}
