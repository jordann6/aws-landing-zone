output "scan_target_role_arns" {
  description = "Metadata-only member-account targets for aws-secrets-lifecycle"
  value = [
    for id in [
      local.acct.log_archive_account_id,
      local.acct.network_account_id,
      local.acct.shared_services_account_id,
      local.acct.dev_account_id,
      local.acct.test_account_id,
      local.acct.prod_account_id,
      local.acct.sandbox_account_id,
    ] : "arn:aws:iam::${id}:role/${var.scanner_prefix}-scan-target-role"
  ]
}

output "scanner_deploy_role_arn" {
  description = "Role the scanner deploys through: the security account's OrganizationAccountAccessRole"
  value       = "arn:aws:iam::${local.acct.security_account_id}:role/OrganizationAccountAccessRole"
}
