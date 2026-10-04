terraform {
  # removed/import blocks used by the state migration need 1.7.
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "tf-state-jordprojs"
    key          = "aws-scp-governance/accounts.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  # Same allocation identity as the governance root, so the accounts imported
  # from it carry identical tags and plan with no diff. Inline literals so the
  # static OPA policy can read the keys.
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
