terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Its own state: metadata-only IAM roles in every member account ($0 standing
  # cost). Independent of the hourly layers, so it survives demo teardowns.
  backend "s3" {
    bucket       = "jordann6-aws-landing-zone-tfstate"
    key          = "aws-landing-zone/secrets.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
    kms_key_id   = "alias/aws-landing-zone-tfstate"
  }
}

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
  alias  = "security"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.security_account_id}:role/OrganizationAccountAccessRole"
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
  alias  = "log_archive"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.log_archive_account_id}:role/OrganizationAccountAccessRole"
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
  alias  = "network"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.network_account_id}:role/OrganizationAccountAccessRole"
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
  alias  = "shared_services"
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

provider "aws" {
  alias  = "dev"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.dev_account_id}:role/OrganizationAccountAccessRole"
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
  alias  = "test"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.test_account_id}:role/OrganizationAccountAccessRole"
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
  alias  = "sandbox"
  region = var.region
  assume_role {
    role_arn = "arn:aws:iam::${local.acct.sandbox_account_id}:role/OrganizationAccountAccessRole"
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
