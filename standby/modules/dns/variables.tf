variable "domain_name" {
  description = "Hosted zone name"
  type        = string
}

variable "primary_fqdn" {
  description = "Primary region API domain"
  type        = string
}

variable "secondary_fqdn" {
  description = "Standby region API domain"
  type        = string
}
