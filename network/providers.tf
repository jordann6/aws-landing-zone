terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Its own state, separate from the governance root, so the hourly inspection
  # layer can be deployed for a demo and destroyed on its own without touching
  # the always-on governance state.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/network.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

# Assumes into the network account. The account id comes from the persistent
# accounts state; the role comes from the CI stage (ci.tf).
provider "aws" {
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${data.terraform_remote_state.accounts.outputs.network_account_id}:role/${local.member_role_name}"
  }

  default_tags {
    tags = {
      Project     = "aws-landing-zone"
      Environment = "network"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

# Reading the persistent sharing marker before configuring the network provider
# prevents creating billable layers when RAM onboarding has been skipped.
data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/accounts.tfstate"
    region = "us-east-1"
  }
  lifecycle {
    postcondition {
      condition     = try(self.outputs.ram_organization_sharing_enabled, false)
      error_message = "Apply the persistent accounts RAM-sharing prerequisite before planning the hourly network layer."
    }
    postcondition {
      condition     = var.network_account_id == null || self.outputs.network_account_id == var.network_account_id
      error_message = "The network account input must match the persistent account state."
    }
  }
}

locals {
  # null reads the Organization from the accounts state; "" skips the RAM share.
  org_arn = var.org_arn == null ? data.terraform_remote_state.accounts.outputs.organization_arn : var.org_arn
}
