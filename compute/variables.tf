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

variable "enable_management_instance" {
  description = "Deploy the hardened management instance. Part of every standard deploy; false only for a plan without a golden AMI."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "Smallest burstable size; the instance is a management and proof host, not a workload"
  type        = string
  default     = "t3.micro"
}
