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

output "sandbox_account_id" {
  value = aws_organizations_account.sandbox.id
}

output "dev_account_id" {
  value = aws_organizations_account.dev.id
}

output "prod_account_id" {
  value = aws_organizations_account.prod.id
}

output "test_account_id" {
  value = aws_organizations_account.test.id
}

output "security_account_id" {
  value = aws_organizations_account.security.id
}

output "network_account_id" {
  description = "Consumed by the network/ root to assume into this account"
  value       = aws_organizations_account.network.id
}

output "shared_services_account_id" {
  value = aws_organizations_account.shared_services.id
}

output "log_archive_account_id" {
  description = "Consumed by the logging layer as the CloudTrail/Config destination"
  value       = aws_organizations_account.log_archive.id
}
