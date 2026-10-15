# Outputs named in contract-allowlist.txt are published to SSM as the deployment
# contract (ADR-0005). Adding an output here does not publish it.

output "generation_id" {
  value = random_id.generation.hex
}

output "region" {
  value = var.region
}

output "cluster_name" {
  value = local.workload.eks_cluster_name
}

output "namespace" {
  value = var.app_namespace
}

output "app_repository_url" {
  value = aws_ecr_repository.this["app"].repository_url
}

output "deploy_repository_url" {
  value = aws_ecr_repository.this["deploy"].repository_url
}

output "publish_role_arn" {
  value = aws_iam_role.github["publish"].arn
}

output "promote_role_arn" {
  value = aws_iam_role.github["promote"].arn
}

output "app_role_arn" {
  value = aws_iam_role.irsa["orders-api"].arn
}

output "migrator_role_arn" {
  value = aws_iam_role.irsa["orders-migrate"].arn
}

output "verifier_role_arn" {
  value = aws_iam_role.irsa["verifier"].arn
}

output "flux_source_role_arn" {
  value = aws_iam_role.irsa["flux-source"].arn
}

output "deployment_table" {
  value = aws_dynamodb_table.deployments.name
}

# Platform bootstrap only (not part of the contract).
output "verifier_repository_url" {
  value = aws_ecr_repository.this["verifier"].repository_url
}

output "postgres_tools_repository_url" {
  value = aws_ecr_repository.this["tools-postgres"].repository_url
}

output "flux_mirror_repository_urls" {
  value = {
    source_controller    = aws_ecr_repository.this["flux-source-controller"].repository_url
    kustomize_controller = aws_ecr_repository.this["flux-kustomize"].repository_url
  }
}
