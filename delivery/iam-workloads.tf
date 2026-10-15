# In-cluster identities through IRSA (ADR-0004). Each trusts exactly one Kubernetes
# service account. The application's role is not the External Secrets role.

locals {
  irsa = {
    flux-source    = "system:serviceaccount:flux-system:source-controller"
    verifier       = "system:serviceaccount:release-verifier:verifier"
    orders-api     = "system:serviceaccount:${var.app_namespace}:orders-api"
    orders-migrate = "system:serviceaccount:${var.app_namespace}:orders-migrator"
  }
  rds_dbuser_arn = "arn:${local.partition}:rds-db:${var.region}:${local.account}:dbuser:${local.workload.db_resource_id}"
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.eks_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.eks_issuer}:sub"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.eks_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  for_each             = data.aws_iam_policy_document.irsa_trust
  name                 = "${local.name}-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "flux_source" {
  #checkov:skip=CKV_AWS_111:ecr:GetAuthorizationToken does not support resource scoping.
  #checkov:skip=CKV_AWS_356:ecr:GetAuthorizationToken does not support resource scoping.
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "PullReleaseArtifacts"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:ListImages"]
    resources = [local.repo_arns["deploy"]]
  }
}

data "aws_iam_policy_document" "verifier" {
  statement {
    sid       = "ReadDeploymentState"
    actions   = ["dynamodb:GetItem"]
    resources = [local.table_arn]
  }
  # Verdicts only.
  statement {
    sid       = "WriteVerdicts"
    actions   = ["dynamodb:PutItem"]
    resources = [local.table_arn]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "dynamodb:LeadingKeys"
      values   = ["VERIFY#${var.environment}#*"]
    }
  }
  statement {
    sid       = "TableEncryption"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.delivery.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["dynamodb.${var.region}.amazonaws.com"]
    }
  }
}

# IAM database authentication: each role may connect as exactly one database user.
data "aws_iam_policy_document" "db_connect" {
  for_each = { orders-api = "orders_app", orders-migrate = "orders_migrator" }
  statement {
    actions   = ["rds-db:connect"]
    resources = ["${local.rds_dbuser_arn}/${each.value}"]
  }
}

resource "aws_iam_role_policy" "flux_source" {
  name   = "pull-release-artifacts"
  role   = aws_iam_role.irsa["flux-source"].id
  policy = data.aws_iam_policy_document.flux_source.json
}

resource "aws_iam_role_policy" "verifier" {
  name   = "record-verdicts"
  role   = aws_iam_role.irsa["verifier"].id
  policy = data.aws_iam_policy_document.verifier.json
}

resource "aws_iam_role_policy" "db_connect" {
  for_each = data.aws_iam_policy_document.db_connect
  name     = "rds-iam-connect"
  role     = aws_iam_role.irsa[each.key].id
  policy   = each.value.json
}
