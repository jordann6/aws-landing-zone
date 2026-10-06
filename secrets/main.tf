# One metadata-only scan-target role per member account. The scanner itself
# stays in its home account (~/aws-secrets-lifecycle); each role trusts only
# that exact scanner role, inside this organization.
module "security" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.security }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "log_archive" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.log_archive }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "network" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.network }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "shared_services" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.shared_services }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "dev" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.dev }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "test" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.test }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "prod" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.prod }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}

module "sandbox" {
  source             = "./modules/scan-target"
  providers          = { aws = aws.sandbox }
  scanner_role_arn   = local.scanner_role_arn
  scanner_account_id = local.scanner_account_id
  organization_id    = local.acct.organization_id
  role_name          = "${var.scanner_prefix}-scan-target-role"
}
