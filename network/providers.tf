terraform {
  required_version = ">= 1.6.0"

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
    bucket       = "tf-state-jordprojs"
    key          = "aws-scp-governance/network.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Assumes into the network account. The account id comes from the governance
# root's `network_account_id` output; make deploy wires it in.
provider "aws" {
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
