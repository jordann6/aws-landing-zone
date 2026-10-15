terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Its own state: the application delivery layer for release-guard (ECR, the
  # deployment table, the release and workload identities). Applied by the
  # operator after workload; routine releases never touch it.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/delivery.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

# Prod workload account, where EKS and RDS live.
provider "aws" {
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${var.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project            = "aws-landing-zone"
      Environment        = "prod"
      Owner              = var.owner
      ManagedBy          = "terraform"
      CostCenter         = var.cost_center
      DataClassification = "internal"
      Application        = "release-guard"
    }
  }
}
