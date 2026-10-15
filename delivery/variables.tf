variable "region" {
  description = "Deployment region"
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "jordan"
}

variable "cost_center" {
  description = "CostCenter tag (cc-NNNN)"
  type        = string
  default     = "cc-0001"
}

variable "prod_account_id" {
  description = "Prod workload account ID. null (the default) reads prod_account_id from the accounts state."
  type        = string
  default     = null
}

variable "github_repository" {
  description = "Repository whose workflows may assume the release roles, in the immutable OIDC subject form owner@id/repo@id (release-guard emits immutable subjects)"
  type        = string
  default     = "jordann6@196278615/release-guard@1420344268"
}

variable "environment" {
  description = "Deployment environment name used in table keys and the contract path"
  type        = string
  default     = "prod"
}

variable "app_namespace" {
  description = "Kubernetes namespace of the application"
  type        = string
  default     = "orders"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider in the prod account (false if it already exists)"
  type        = bool
  default     = true
}

variable "state_bucket" {
  description = "Terraform state bucket holding the workload state"
  type        = string
  default     = "jordann6-aws-landing-zone-tfstate"
}
