terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Its own state: finding routing, the monitoring account, and central alarms.
  # Nearly free while up (two KMS keys, a handful of alarms) and destroyed with
  # the rest of the stack.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/observability.tfstate"
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
      Project     = "aws-scp-governance"
      Environment = "platform"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

# Security account: GuardDuty and Security Hub administrator, so every member
# account's findings arrive on its default event bus.
provider "aws" {
  alias  = "security"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.security_account_id}:role/${local.org_access_role}"
  }

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

# Shared-services doubles as the monitoring account: the OAM sink, the ops topic,
# and every cross-account alarm live here.
provider "aws" {
  alias  = "monitoring"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.monitoring_account_id}:role/${local.org_access_role}"
  }

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

# Source accounts: each creates an OAM link to the monitoring sink.
provider "aws" {
  alias  = "prod"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.prod_account_id}:role/${local.org_access_role}"
  }

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

provider "aws" {
  alias  = "network"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${local.network_account_id}:role/${local.org_access_role}"
  }

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
