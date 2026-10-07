variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL major version, primary only"
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Initial database name, primary only"
  type        = string
  default     = null
}

variable "username" {
  description = "Master username, primary only"
  type        = string
  default     = null
}

variable "password" {
  description = "Master password, primary only"
  type        = string
  default     = null
  sensitive   = true
}

variable "replicate_source_db" {
  description = "ARN of the source instance. Set only for the cross-region replica"
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "KMS key ARN in the replica region, replica only"
  type        = string
  default     = null
}

variable "db_subnet_group_name" {
  description = "DB subnet group in this region"
  type        = string
}

variable "security_group_id" {
  description = "Security group for the instance"
  type        = string
}
