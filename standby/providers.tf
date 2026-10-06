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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Its own state. The Phase D warm standby is the hourly layer for the DR
  # proof: deployed for a short session and destroyed on its own.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/standby.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/accounts.tfstate"
    region = "us-east-1"
  }
}

locals {
  prod_account_id = data.terraform_remote_state.accounts.outputs.prod_account_id
  name            = var.project_name

  default_tags = {
    Project            = "aws-landing-zone"
    Environment        = "prod"
    Owner              = var.owner
    ManagedBy          = "terraform"
    CostCenter         = var.cost_center
    DataClassification = "confidential"
  }

  # Secrets Manager replicas keep the name and suffix, only the region
  # segment of the ARN differs.
  secret_arn_secondary = replace(
    aws_secretsmanager_secret.db.arn,
    var.primary_region,
    var.secondary_region,
  )
}

# Both regions are in the prod account. The standby region is only reachable
# here because the region-lockdown SCP carries a prod-only exception for it.
provider "aws" {
  alias  = "primary"
  region = var.primary_region

  assume_role {
    role_arn = "arn:aws:iam::${local.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  assume_role {
    role_arn = "arn:aws:iam::${local.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = local.default_tags
  }
}
