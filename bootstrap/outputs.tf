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

output "state_bucket" {
  description = "Dedicated state bucket every root's backend points at"
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_alias" {
  description = "Alias of the state CMK (backend kms_key_id)"
  value       = aws_kms_alias.state.name
}
