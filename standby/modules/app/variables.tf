variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "region_role" {
  description = "Label returned by the API, primary or secondary"
  type        = string
}

variable "lambda_zip" {
  description = "Path to the packaged app zip"
  type        = string
}

variable "lambda_zip_hash" {
  description = "Base64 sha256 of the packaged app zip"
  type        = string
}

variable "db_host" {
  description = "PostgreSQL endpoint for this region"
  type        = string
}

variable "db_name" {
  description = "Database name"
  type        = string
}

variable "db_username" {
  description = "Database username"
  type        = string
}

variable "secret_arn" {
  description = "Secrets Manager ARN holding the DB credentials in this region"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the Lambda"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group for the Lambda"
  type        = string
}

variable "kms_key_arn" {
  description = "CMK that encrypts the DB secret in this region"
  type        = string
}
