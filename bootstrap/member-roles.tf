# Per-member-account CI roles (ADR-0004). The hourly roots (network, workload,
# delivery) assume into these instead of OrganizationAccountAccessRole when they
# run in CI, so the read-only plan identity stays read-only in every account it
# touches. Local operator runs keep using OrganizationAccountAccessRole.

data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${var.state_key_prefix}/accounts.tfstate"
    region = var.region
  }
}

locals {
  member_accounts = {
    network = data.terraform_remote_state.accounts.outputs.network_account_id
    prod    = data.terraform_remote_state.accounts.outputs.prod_account_id
  }
}

module "network_ci_roles" {
  source    = "./modules/member-ci-roles"
  providers = { aws = aws.network }

  plan_principal_arn  = aws_iam_role.gha_plan.arn
  apply_principal_arn = aws_iam_role.gha_apply.arn
}

module "prod_ci_roles" {
  source    = "./modules/member-ci-roles"
  providers = { aws = aws.prod }

  plan_principal_arn  = aws_iam_role.gha_plan.arn
  apply_principal_arn = aws_iam_role.gha_apply.arn
}
