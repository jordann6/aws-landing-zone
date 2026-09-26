terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "tf-state-jordprojs"
    key          = "aws-scp-governance/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
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
# assume_role references the account id created earlier in this same root.
# Terraform creates the accounts first, then uses these providers for the
# resources that depend on them. If a first apply races that ordering, re-running
# apply settles it; the accounts already exist by then.
provider "aws" {
  alias  = "log_archive"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${aws_organizations_account.log_archive.id}:role/${local.org_access_role}"
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
    role_arn = "arn:aws:iam::${aws_organizations_account.security.id}:role/${local.org_access_role}"
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
