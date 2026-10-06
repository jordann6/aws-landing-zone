terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

locals {
  org_access_role = "OrganizationAccountAccessRole"
}

provider "aws" {
  region = var.region

  # Fleet-wide allocation identity. These keys satisfy the shared OPA tag and
  # FinOps policies for every taggable resource this root creates, and they are
  # what the org tag policy enforces. Kept as inline literals (not a local) so the
  # static policy can read the keys. Per-resource tags still override.
  default_tags {
    tags = {
      Project     = "aws-scp-governance"
      Environment = "platform"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

# Aliased providers that assume into the member accounts this root configures.
# The network account is deliberately not here: it is a separate root, so its
# pricey, timed infrastructure can be deployed and destroyed on its own.
#
# assume_role reads the account ids from the accounts/ root's state, so the
# accounts must exist (accounts/ applied) before this root plans.
provider "aws" {
  alias  = "log_archive"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.log_archive_account_id}:role/${local.org_access_role}"
  }

  default_tags {
    tags = {
      Project     = "aws-scp-governance"
      Environment = "log-archive"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

provider "aws" {
  alias  = "security"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.security_account_id}:role/${local.org_access_role}"
  }

  default_tags {
    tags = {
      Project     = "aws-scp-governance"
      Environment = "security"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
