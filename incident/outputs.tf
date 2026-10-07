output "forensics_target_role_arns" {
  description = "Per-step forensics target roles in prod, keyed by step"
  value       = { for k, r in aws_iam_role.forensics : k => r.arn }
}

output "alarm_reader_role_arn" {
  value = aws_iam_role.alarm_reader.arn
}

output "forensics_deploy_role_arn" {
  description = "Role the forensics stack deploys through (security account)"
  value       = "arn:aws:iam::${local.security_account_id}:role/OrganizationAccountAccessRole"
}

output "responder_deploy_role_arn" {
  description = "Role the responder stack deploys through (prod)"
  value       = "arn:aws:iam::${local.prod_account_id}:role/OrganizationAccountAccessRole"
}

output "prod_account_id" {
  value = local.prod_account_id
}

output "organization_id" {
  value = local.acct.organization_id
}

output "n8n_repository_url" {
  value = aws_ecr_repository.n8n.repository_url
}
