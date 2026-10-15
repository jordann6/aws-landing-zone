output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = local.oidc_provider_arn
}

output "plan_role_arn" {
  description = "Put this in guardrails.yml (plan) and ttl-guard.yml as aws_role_arn"
  value       = aws_iam_role.gha_plan.arn
}

output "apply_role_arn" {
  description = "Put this in apply.yml (apply_role_arn) and destroy.yml (aws_role_arn)"
  value       = aws_iam_role.gha_apply.arn
}

output "member_ci_role_arns" {
  description = "Per-member-account CI roles the hourly roots assume in CI (plan read-only, apply write)"
  value = {
    network = module.network_ci_roles
    prod    = module.prod_ci_roles
  }
}

output "state_bucket" {
  description = "Dedicated state bucket every root's backend points at"
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_alias" {
  description = "Alias of the state CMK (backend kms_key_id)"
  value       = aws_kms_alias.state.name
}
