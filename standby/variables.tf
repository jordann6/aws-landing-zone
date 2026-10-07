variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "lz-standby"
}

variable "primary_region" {
  description = "Primary region. Keep us-east-1: Route 53 health check metrics only publish to CloudWatch in us-east-1"
  type        = string
  default     = "us-east-1"
}

variable "secondary_region" {
  description = "Standby region. Must match standby_region in the accounts root SCP exception"
  type        = string
  default     = "us-west-2"
}

variable "owner" {
  type    = string
  default = "jordan"
}

variable "cost_center" {
  type    = string
  default = "cc-0001"
}

variable "domain_name" {
  description = "Hosted zone for the failover records. Routing is proven with route53 test-dns-answer, so it does not need delegation"
  type        = string
  default     = "failover.jordandesigns.io"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_name" {
  type    = string
  default = "orders"
}

variable "db_username" {
  type    = string
  default = "app_admin"
}

variable "notification_email" {
  description = "Email for failover notices. Leave empty to skip the subscription"
  type        = string
  default     = ""
}
