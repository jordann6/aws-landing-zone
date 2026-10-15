# GitHub Actions identities (ADR-0004). Each role trusts only its own deployment
# environments in one repository, and those environments only accept main.

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  repo_arns           = { for k, r in aws_ecr_repository.this : k => r.arn }
  table_arn           = aws_dynamodb_table.deployments.arn
}

data "aws_iam_policy_document" "github_trust" {
  for_each = {
    publish = ["publish"]
    promote = ["production", "production-override"]
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for env in each.value : "repo:${var.github_repository}:environment:${env}"]
    }
  }
}

# Ceiling for both GitHub roles: only the services a release uses, only this region,
# and never repository or table administration.
data "aws_iam_policy_document" "github_boundary" {
  #checkov:skip=CKV_AWS_356:Boundary ceiling; the identity policies scope resources.
  #checkov:skip=CKV_AWS_111:Boundary ceiling; the identity policies scope resources.
  #checkov:skip=CKV_AWS_109:Boundary ceiling; the identity policies scope resources.
  #checkov:skip=CKV_AWS_108:Boundary ceiling grants nothing alone; reads are scoped to specific ARNs in the identity policies.
  statement {
    sid = "ReleaseServices"
    actions = [
      "ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages", "ecr:ListImages", "ecr:ListTagsForResource",
      "ssm:GetParameter", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
      "kms:Decrypt", "kms:GenerateDataKey", "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
  statement {
    sid    = "NoAdministration"
    effect = "Deny"
    actions = [
      "ecr:DeleteRepository", "ecr:BatchDeleteImage", "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy",
      "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy", "ecr:TagResource", "ecr:UntagResource",
      "ecr:PutImageTagMutability", "ecr:PutImageScanningConfiguration",
    ]
    resources = ["*"]
  }
  statement {
    sid         = "ThisRegionOnly"
    effect      = "Deny"
    not_actions = ["sts:GetCallerIdentity"]
    resources   = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }
}

resource "aws_iam_policy" "github_boundary" {
  name   = "${local.name}-github-boundary"
  policy = data.aws_iam_policy_document.github_boundary.json
}

resource "aws_iam_role" "github" {
  for_each             = data.aws_iam_policy_document.github_trust
  name                 = "${local.name}-${each.key}"
  assume_role_policy   = each.value.json
  permissions_boundary = aws_iam_policy.github_boundary.arn
  max_session_duration = 3600
}

data "aws_iam_policy_document" "publish" {
  #checkov:skip=CKV_AWS_111:ecr:GetAuthorizationToken does not support resource scoping.
  #checkov:skip=CKV_AWS_356:ecr:GetAuthorizationToken does not support resource scoping.
  statement {
    sid       = "ReadContract"
    actions   = ["ssm:GetParameter"]
    resources = [local.contract_parameter_arn]
  }
  statement {
    sid       = "RegistryLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushApplicationImages"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.repo_arns["app"]]
  }
  statement {
    sid       = "CheckContractGeneration"
    actions   = ["ecr:ListTagsForResource"]
    resources = [local.repo_arns["deploy"]]
  }
}

data "aws_iam_policy_document" "promote" {
  #checkov:skip=CKV_AWS_111:ecr:GetAuthorizationToken does not support resource scoping.
  #checkov:skip=CKV_AWS_356:ecr:GetAuthorizationToken does not support resource scoping.
  statement {
    sid       = "ReadContract"
    actions   = ["ssm:GetParameter"]
    resources = [local.contract_parameter_arn]
  }
  statement {
    sid       = "RegistryLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadApplicationImages"
    actions   = ["ecr:BatchGetImage", "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [local.repo_arns["app"]]
  }
  statement {
    sid = "PublishReleaseArtifacts"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer", "ecr:ListImages", "ecr:ListTagsForResource",
    ]
    resources = [local.repo_arns["deploy"]]
  }
  statement {
    sid       = "ReadDeploymentState"
    actions   = ["dynamodb:GetItem"]
    resources = [local.table_arn]
  }
  # The pipeline may take the lock, record releases and grant overrides, but never
  # write a verdict: only the in-cluster verifier can (ADR-0004, ADR-0006).
  statement {
    sid       = "WriteReleaseState"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [local.table_arn]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "dynamodb:LeadingKeys"
      values   = ["LOCK#${var.environment}", "DEPLOY#${var.environment}#*", "OVERRIDE#${var.environment}#*"]
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

resource "aws_iam_role_policy" "publish" {
  name   = "publish"
  role   = aws_iam_role.github["publish"].id
  policy = data.aws_iam_policy_document.publish.json
}

resource "aws_iam_role_policy" "promote" {
  name   = "promote"
  role   = aws_iam_role.github["promote"].id
  policy = data.aws_iam_policy_document.promote.json
}
