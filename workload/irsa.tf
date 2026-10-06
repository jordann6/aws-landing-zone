# IRSA worked example: the External Secrets Operator. Its pod assumes this role
# through the cluster OIDC provider, scoped by service account, and can read only
# the RDS master secret. No static keys, no node-wide credentials: the pod gets
# exactly one secret. This is the sanctioned secrets path (ESO pulling from
# Secrets Manager via workload identity) from the design.

locals {
  oidc_host = var.enable_eks ? replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "") : ""
}

data "aws_iam_policy_document" "eso_trust" {
  count = var.enable_eks && var.enable_rds ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  count              = var.enable_eks && var.enable_rds ? 1 : 0
  name               = "prod-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.eso_trust[0].json
}

data "aws_iam_policy_document" "eso" {
  count = var.enable_eks && var.enable_rds ? 1 : 0
  statement {
    sid       = "ReadRdsSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_db_instance.prod[0].master_user_secret[0].secret_arn]
  }
  statement {
    sid       = "DecryptWithDataKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data[0].arn]
  }
}

resource "aws_iam_role_policy" "eso" {
  count  = var.enable_eks && var.enable_rds ? 1 : 0
  name   = "read-rds-secret"
  role   = aws_iam_role.eso[0].id
  policy = data.aws_iam_policy_document.eso[0].json
}
