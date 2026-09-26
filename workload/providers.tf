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

  # Its own state. This is the paved-road prod workload (data tier + EKS): the
  # hourly-billed layer, deployed for a demo and destroyed on its own.
  backend "s3" {
    bucket       = "tf-state-jordprojs"
    key          = "aws-scp-governance/workload.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Prod workload account: the VPC, data tier, and EKS live here.
provider "aws" {
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project            = "aws-scp-governance"
      Environment        = "prod"
      Owner              = var.owner
      ManagedBy          = "terraform"
      CostCenter         = var.cost_center
      DataClassification = "confidential"
    }
  }
}

# Network account: accepts the cross-account TGW attachment from the prod VPC.
provider "aws" {
  alias  = "network"
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.network_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project     = "aws-scp-governance"
      Environment = "network"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

# DR region in the prod account, the cross-region copy destination for backups.
# Demo scope: the vault is Vault-Lock WORM but lives in the prod account.
# Production isolates it in a separate backup account via AWS Backup cross-account
# copy and an org backup policy; that is documented, not faked here.
provider "aws" {
  alias  = "prod_dr"
  region = var.dr_region

  assume_role {
    role_arn = "arn:aws:iam::${var.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project     = "aws-scp-governance"
      Environment = "prod"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}
