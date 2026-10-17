# Account ids come from the persistent accounts/ root, so no member account id
# is hardcoded here.
data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/accounts.tfstate"
    region = "us-east-1"
  }
}

locals {
  acct            = data.terraform_remote_state.accounts.outputs
  prod_account_id = local.acct.prod_account_id
}
