data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The prod account id comes from the persistent accounts state (ADR-0004); an
# explicit prod_account_id still wins.
data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket     = var.state_bucket
    key        = "aws-landing-zone/accounts.tfstate"
    region     = var.region
    kms_key_id = "alias/aws-landing-zone-tfstate"
  }
}

# Consumed from the workload root rather than repeating its resource names.
data "terraform_remote_state" "workload" {
  backend = "s3"
  config = {
    bucket     = var.state_bucket
    key        = "aws-landing-zone/workload.tfstate"
    region     = var.region
    kms_key_id = "alias/aws-landing-zone-tfstate"
  }
}

locals {
  prod_account_id = coalesce(var.prod_account_id, data.terraform_remote_state.accounts.outputs.prod_account_id)

  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  workload  = data.terraform_remote_state.workload.outputs
  name      = "release-guard"

  contract_parameter_arn = "arn:${local.partition}:ssm:${var.region}:${local.account}:parameter/delivery/${local.name}/${var.environment}/contract"
  eks_issuer             = local.workload.eks_oidc_issuer
  eks_oidc_provider_arn  = local.workload.eks_oidc_provider_arn
}
