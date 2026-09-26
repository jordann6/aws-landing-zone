output "prod_vpc_id" {
  value = aws_vpc.prod.id
}

output "db_endpoint" {
  description = "RDS endpoint (private)"
  value       = aws_db_instance.prod.address
}

output "db_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credential"
  value       = aws_db_instance.prod.master_user_secret[0].secret_arn
}

output "backup_vault_arn" {
  value = aws_backup_vault.prod.arn
}

output "data_subnet_ids" {
  value = local.data_subnet_ids
}

output "node_subnet_ids" {
  value = local.node_subnet_ids
}

output "eks_cluster_name" {
  value = aws_eks_cluster.prod.name
}

output "eks_cluster_endpoint" {
  description = "Private EKS API endpoint (reachable only over the TGW/hub)"
  value       = aws_eks_cluster.prod.endpoint
}

output "eks_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "external_secrets_role_arn" {
  description = "IRSA role for the External Secrets Operator service account"
  value       = aws_iam_role.eso.arn
}
