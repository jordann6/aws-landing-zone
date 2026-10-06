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
  acct               = data.terraform_remote_state.accounts.outputs
  scanner_account_id = local.acct.security_account_id
  scanner_role_arn   = "arn:aws:iam::${local.scanner_account_id}:role/${var.scanner_prefix}-scanner-role"
}
