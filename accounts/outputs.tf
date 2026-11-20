output "organization_id" {
  value = aws_organizations_organization.org.id
}

output "organization_arn" {
  description = "Consumed by the network/ root to share the TGW to the org via RAM"
  value       = aws_organizations_organization.org.arn
}

output "organization_root_id" {
  value = aws_organizations_organization.org.roots[0].id
}

output "management_account_id" {
  value = aws_organizations_organization.org.master_account_id
}

output "security_ou_id" {
  value = aws_organizations_organizational_unit.security.id
}

output "infrastructure_ou_id" {
  value = aws_organizations_organizational_unit.infrastructure.id
}

output "sandbox_ou_id" {
  value = aws_organizations_organizational_unit.sandbox.id
}

output "workloads_ou_id" {
  value = aws_organizations_organizational_unit.workloads.id
}

output "dev_ou_id" {
  value = aws_organizations_organizational_unit.dev.id
}

output "test_ou_id" {
  value = aws_organizations_organizational_unit.test.id
}

output "prod_ou_id" {
  value = aws_organizations_organizational_unit.prod.id
}

output "suspended_ou_id" {
  value = aws_organizations_organizational_unit.suspended.id
}

output "deployments_ou_id" {
  value = aws_organizations_organizational_unit.deployments.id
}

output "sandbox_account_id" {
  value = aws_organizations_account.this["sandbox"].id
}

# dev/prod/test/network/shared-services exist only when full_account_set is true;
# try(...) yields null when the account is gated off.
output "dev_account_id" {
  value = try(aws_organizations_account.this["dev"].id, null)
}

output "prod_account_id" {
  value = try(aws_organizations_account.this["prod"].id, null)
}

output "test_account_id" {
  value = try(aws_organizations_account.this["test"].id, null)
}

output "security_account_id" {
  value = aws_organizations_account.this["security"].id
}

output "network_account_id" {
  description = "Consumed by the network/ root to assume into this account"
  value       = try(aws_organizations_account.this["network"].id, null)
}

output "shared_services_account_id" {
  value = try(aws_organizations_account.this["shared-services"].id, null)
}

output "log_archive_account_id" {
  description = "Consumed by the logging layer as the CloudTrail/Config destination"
  value       = aws_organizations_account.this["log-archive"].id
}

output "cicd_account_id" {
  description = "Dedicated CI/CD account in the Deployments OU; null unless deployments_account_enabled"
  value       = try(aws_organizations_account.this["cicd"].id, null)
}

output "account_ids" {
  description = "Every vended member account, name => id"
  value       = { for name, a in aws_organizations_account.this : name => a.id }
}
