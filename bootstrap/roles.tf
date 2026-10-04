locals {
  sub_prefix    = "repo:${var.github_org}/${var.github_repo}"
  state_bucket  = "arn:aws:s3:::${var.state_bucket}"
  state_objects = "arn:aws:s3:::${var.state_bucket}/${var.state_key_prefix}/*"
}

# --- Shared state access (both roles read/write this repo's state) ------------
# use_lockfile stores the lock as an S3 object beside the state, so both roles
# need Put/Delete on the object prefix, not just Get. No DynamoDB table exists.
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.state_key_prefix}/*"]
    }
  }
  statement {
    sid       = "ReadWriteState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.state_objects]
  }
}

# ============================================================================
# gha-plan: read-scoped. Assumable from PRs and from main. Refreshes and plans
# the org config; it can read everything the plan touches and write nothing.
# ============================================================================
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.sub_prefix}:ref:refs/heads/main",
        "${local.sub_prefix}:pull_request",
      ]
    }
  }
}

data "aws_iam_policy_document" "plan_permissions" {
  statement {
    sid       = "ReadOrganization"
    actions   = ["organizations:Describe*", "organizations:List*"]
    resources = ["*"]
  }
  statement {
    sid       = "ReadIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "gha_plan" {
  name                 = "gha-plan"
  description          = "Read-scoped role for GitHub Actions Terraform plan (OIDC)"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gha_plan_read" {
  name   = "read-org-and-state"
  role   = aws_iam_role.gha_plan.id
  policy = data.aws_iam_policy_document.plan_read_combined.json
}

data "aws_iam_policy_document" "plan_read_combined" {
  source_policy_documents = [
    data.aws_iam_policy_document.plan_permissions.json,
    data.aws_iam_policy_document.state_access.json,
  ]
}

# ============================================================================
# gha-apply: write-scoped. Assumable ONLY from a job bound to one of the gated
# environments. The required reviewer on those environments is the JIT-to-prod
# control: no standing permission to change the org.
# ============================================================================
data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for env in var.apply_environments : "${local.sub_prefix}:environment:${env}"]
    }
  }
}

# Managing an AWS Organization is an all-or-nothing API surface: most
# organizations:* actions do not support resource-level scoping, so the write
# role gets the org actions plus the service-linked role creation the console and
# API need, and nothing beyond that. The reviewer gate, not IAM resource scoping,
# is what constrains when this is used.
data "aws_iam_policy_document" "apply_permissions" {
  statement {
    sid       = "ManageOrganization"
    actions   = ["organizations:*"]
    resources = ["*"]
  }
  statement {
    sid     = "ServiceLinkedRoles"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:aws:iam::*:role/aws-service-role/*",
    ]
  }
  statement {
    sid       = "ReadIdentity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "apply_write_combined" {
  source_policy_documents = [
    data.aws_iam_policy_document.apply_permissions.json,
    data.aws_iam_policy_document.state_access.json,
  ]
}

resource "aws_iam_role" "gha_apply" {
  name                 = "gha-apply"
  description          = "Write-scoped role for GitHub Actions Terraform apply/destroy (OIDC, environment-gated)"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "gha_apply_write" {
  name   = "manage-org-and-state"
  role   = aws_iam_role.gha_apply.id
  policy = data.aws_iam_policy_document.apply_write_combined.json
}
