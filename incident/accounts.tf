# Account ids come from the persistent accounts/ root; none are hardcoded.
data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/accounts.tfstate"
    region = "us-east-1"
  }
}

locals {
  acct = data.terraform_remote_state.accounts.outputs

  security_account_id   = local.acct.security_account_id
  prod_account_id       = local.acct.prod_account_id
  monitoring_account_id = local.acct.shared_services_account_id
}
