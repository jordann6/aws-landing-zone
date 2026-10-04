# Account ids come from the persistent accounts/ root, so this root needs no
# -var plumbing and never hardcodes an account id.
data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = "tf-state-jordprojs"
    key    = "aws-scp-governance/accounts.tfstate"
    region = "us-east-1"
  }
}

locals {
  acct = data.terraform_remote_state.accounts.outputs

  security_account_id   = local.acct.security_account_id
  monitoring_account_id = local.acct.shared_services_account_id
  prod_account_id       = local.acct.prod_account_id
  network_account_id    = local.acct.network_account_id
}
