output "prod_vpc_id" {
  value = aws_vpc.prod.id
}

output "db_endpoint" {
  description = "RDS endpoint (private)"
  value       = var.enable_rds ? aws_db_instance.prod[0].address : null
}

output "db_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master credential"
  value       = var.enable_rds ? aws_db_instance.prod[0].master_user_secret[0].secret_arn : null
}

output "backup_vault_arn" {
  value = var.enable_rds ? aws_backup_vault.prod[0].arn : null
}

output "data_subnet_ids" {
  value = local.data_subnet_ids
}

output "node_subnet_ids" {
  value = local.node_subnet_ids
}

output "eks_cluster_name" {
  value = var.enable_eks ? aws_eks_cluster.prod[0].name : null
}

output "eks_cluster_endpoint" {
  description = "Private EKS API endpoint (reachable only over the TGW/hub)"
  value       = var.enable_eks ? aws_eks_cluster.prod[0].endpoint : null
}

output "eks_oidc_provider_arn" {
  value = var.enable_eks ? aws_iam_openid_connect_provider.eks[0].arn : null
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "external_secrets_role_arn" {
  description = "IRSA role for the External Secrets Operator service account"
  value       = var.enable_eks && var.enable_rds ? aws_iam_role.eso[0].arn : null
}

# ---- compute baseline (read by the compute/ root and make build-image) ----------

output "app_subnet_ids" {
  description = "Private app-tier subnets; the management instance lands in the first"
  value       = [for k, s in local.subnets : aws_subnet.this[k].id if s.tier == "app"]
}

output "s3_prefix_list_id" {
  description = "S3 gateway endpoint prefix list (package repos and staged artifacts)"
  value       = aws_vpc_endpoint.s3.prefix_list_id
}

output "ebs_kms_key_arn" {
  description = "Default EBS CMK for the prod account"
  value       = aws_kms_key.ebs.arn
}

output "golden_image_pipeline_arn" {
  value = aws_imagebuilder_image_pipeline.hardened.arn
}

output "golden_image_name" {
  description = "Name prefix of distributed golden AMIs"
  value       = local.golden_image_name
}

output "golden_image_artifacts_bucket" {
  value = aws_s3_bucket.imagebuilder_artifacts.id
}

output "cis_baseline_release" {
  value = var.cis_baseline_release
}

output "prod_cidr" {
  value = var.prod_cidr
}
