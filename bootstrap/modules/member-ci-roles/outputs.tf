output "plan_role_arn" {
  description = "Read-only member role the plan stage assumes"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Write member role the apply and destroy stages assume"
  value       = aws_iam_role.apply.arn
}
