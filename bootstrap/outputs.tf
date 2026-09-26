output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "plan_role_arn" {
  description = "Put this in guardrails.yml (plan) and ttl-guard.yml as aws_role_arn"
  value       = aws_iam_role.gha_plan.arn
}

output "apply_role_arn" {
  description = "Put this in apply.yml (apply_role_arn) and destroy.yml (aws_role_arn)"
  value       = aws_iam_role.gha_apply.arn
}
