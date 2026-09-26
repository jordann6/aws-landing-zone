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

  # Separate state key in the same bucket the root module uses. Applied once,
  # locally, with admin credentials, to create the CI identities. After that the
  # credentialed workflows use the roles this module outputs; nothing here is in
  # the hourly-cost path.
  backend "s3" {
    bucket       = "tf-state-jordprojs"
    key          = "aws-scp-governance/bootstrap.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-scp-governance"
      Environment = "platform"
      Owner       = "jordan"
      ManagedBy   = "terraform"
      CostCenter  = "cc-0001"
    }
  }
}
