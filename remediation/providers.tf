terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Its own state: a tag-scoped, circuit-broken remediation Lambda in the prod account (near-zero standing cost). Independent of the hourly layers, so it survives demo
  # teardowns.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/remediation.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

locals {
  org_access_role = "OrganizationAccountAccessRole"
}

# default_tags are inline literals in every provider (not a local) so the static
# OPA tag policy can read the keys. Environment = platform is an allowed value.

# Management account: only reads the accounts/ state. No resources land here.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-landing-zone"
      Environment = "platform"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

provider "aws" {
  alias  = "prod"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.prod_account_id}:role/${local.org_access_role}"
  }

  default_tags {
    tags = {
      Project     = "aws-landing-zone"
      Environment = "platform"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
