variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "account_id" {
  description = "AWS account id, used for the cross-region event bus ARN"
  type        = string
}

variable "secondary_region" {
  description = "Standby region hosting the failover Lambda"
  type        = string
}

variable "health_check_id" {
  description = "Route 53 health check watching the primary API"
  type        = string
}

variable "replica_identifier" {
  description = "Identifier of the RDS read replica to promote"
  type        = string
}

variable "replica_arn" {
  description = "ARN of the RDS read replica to promote"
  type        = string
}

variable "lambda_zip" {
  description = "Path to the packaged failover handler zip"
  type        = string
}

variable "lambda_zip_hash" {
  description = "Base64 sha256 of the packaged failover handler zip"
  type        = string
}

variable "notification_email" {
  description = "Email endpoint for failover notifications, empty to skip"
  type        = string
  default     = ""
}
