# CI roles inside one member account, reached by role chaining from the
# management-account OIDC roles in ../../roles.tf:
#
#   GitHub OIDC -> management gha-plan  -> member gha-plan  (read-only)
#   GitHub OIDC -> management gha-apply -> member gha-apply (write, environment-gated)
#
# Each member role trusts exactly one management role, so the pairing is enforced
# by IAM. The roots pick which name to assume from the ephemeral ci_stage
# variable, but a pull request that edits that mapping still cannot reach the
# write role: only the environment-gated management role can assume it.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

data "aws_caller_identity" "this" {}

locals {
  account = data.aws_caller_identity.this.account_id
  protected_roles = [
    "arn:aws:iam::${local.account}:role/gha-plan",
    "arn:aws:iam::${local.account}:role/gha-apply",
    "arn:aws:iam::${local.account}:role/OrganizationAccountAccessRole",
  ]
}

# --- gha-plan: refresh and plan, never write, never read data ----------------
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.plan_principal_arn]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "gha-plan"
  description          = "Read-only Terraform plan role for aws-landing-zone CI, chained from the management gha-plan role"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess covers every Describe/Get/List a refresh needs, and also some
# data-plane reads a plan never needs. A plan reads configuration, not content.
data "aws_iam_policy_document" "plan_no_data" {
  # checkov:skip=CKV_AWS_356:An explicit Deny over every resource is the intent; it narrows, never grants.
  statement {
    sid    = "DenyDataPlaneReads"
    effect = "Deny"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "secretsmanager:GetSecretValue",
      "kms:Decrypt",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan_no_data" {
  name   = "deny-data-plane-reads"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_no_data.json
}

# --- gha-apply: build and tear down the hourly roots ---------------------------
data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.apply_principal_arn]
    }
  }
}

resource "aws_iam_role" "apply" {
  name                 = "gha-apply"
  description          = "Write Terraform role for aws-landing-zone CI, chained from the environment-gated management gha-apply role"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# The network, workload and delivery roots create VPCs, EKS, RDS, KMS keys and
# IAM roles, so the write role is broad by necessity. What bounds it: the
# reviewer on the GitHub environment (when), the Organization SCPs (ceiling), and
# the guard below (no persistence, no tampering with the CI or break-glass roles).
resource "aws_iam_role_policy_attachment" "apply_admin" {
  # checkov:skip=CKV_AWS_274:The member write role builds IAM, EKS, RDS and KMS; the environment reviewer, the SCPs and the explicit deny guard bound it.
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

data "aws_iam_policy_document" "apply_guard" {
  # checkov:skip=CKV_AWS_356:Explicit Deny statements narrow, never grant.
  statement {
    sid       = "NoLongLivedCredentials"
    effect    = "Deny"
    actions   = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile"]
    resources = ["*"]
  }
  statement {
    sid    = "ProtectCIAndBreakGlassRoles"
    effect = "Deny"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
      "iam:DeleteRole",
      "iam:PutRolePermissionsBoundary",
      "iam:DeleteRolePermissionsBoundary",
      "iam:TagRole",
      "iam:UntagRole",
    ]
    resources = local.protected_roles
  }
  statement {
    sid       = "StayInTheOrganization"
    effect    = "Deny"
    actions   = ["organizations:LeaveOrganization"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "apply_guard" {
  name   = "guard"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_guard.json
}
