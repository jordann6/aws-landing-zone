# The org, OUs, member accounts, and SCPs live in the persistent accounts/ root,
# which no teardown touches. This root reads their ids from that state, so it can
# be destroyed and redeployed without closing an account.
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

  org_id                 = local.acct.organization_id
  management_account_id  = local.acct.management_account_id
  security_account_id    = local.acct.security_account_id
  log_archive_account_id = local.acct.log_archive_account_id
}
