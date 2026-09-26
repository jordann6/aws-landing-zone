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
  description = "Consumed by the EKS layer for the node subnets"
  value       = local.node_subnet_ids
}
