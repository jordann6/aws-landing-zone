terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Its own state: IAM roles and one ECR repository (cents a month). The
  # forensics runbook in the security account is a standing control, so these
  # outlive the hourly layers.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/incident.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

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
    role_arn = "arn:aws:iam::${local.acct.prod_account_id}:role/OrganizationAccountAccessRole"
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

provider "aws" {
  alias  = "monitoring"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.shared_services_account_id}:role/OrganizationAccountAccessRole"
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
