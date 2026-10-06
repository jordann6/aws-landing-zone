terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Separate state key in the same bucket the root module uses. Applied once,
  # locally, with admin credentials, to create the CI identities. After that the
  # credentialed workflows use the roles this module outputs; nothing here is in
  # the hourly-cost path.
  # This root creates the bucket it stores state in (state_backend.tf). The first
  # apply runs against the legacy bucket through a temporary override, then the
  # state moves here (scripts/migrate-state-backend.sh, ADR-0003).
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/bootstrap.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-landing-zone"
      Environment = "platform"
      Owner       = "jordan"
      ManagedBy   = "terraform"
      CostCenter  = "cc-0001"
    }
  }
}
