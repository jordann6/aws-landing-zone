terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Its own state: the hardened management instance. Deployed after the workload
  # root and a golden AMI build, destroyed first. Same dedicated backend as every
  # other root (ADR-0003).
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/compute.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

# Prod account, resolved from the persistent accounts state.
provider "aws" {
  region = var.region

  assume_role {
    role_arn = "arn:aws:iam::${data.terraform_remote_state.accounts.outputs.prod_account_id}:role/OrganizationAccountAccessRole"
  }

  default_tags {
    tags = {
      Project            = "aws-scp-governance"
      Environment        = "prod"
      Owner              = var.owner
      ManagedBy          = "terraform"
      CostCenter         = var.cost_center
      DataClassification = "internal"
    }
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

data "terraform_remote_state" "workload" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/workload.tfstate"
    region = "us-east-1"
  }
  lifecycle {
    postcondition {
      condition     = try(self.outputs.golden_image_pipeline_arn, null) != null
      error_message = "Deploy the workload root (with the golden image pipeline) before the compute root."
    }
  }
}
