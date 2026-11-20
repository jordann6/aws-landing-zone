locals {
  # The repository emits immutable OIDC subjects (owner and repo carry their
  # numeric ids), so the plain "repo:owner/name" form never matches.
  sub_prefix = "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"
  member_role_arns = {
    plan  = [for id in values(local.member_accounts) : "arn:aws:iam::${id}:role/gha-plan"]
    apply = [for id in values(local.member_accounts) : "arn:aws:iam::${id}:role/gha-apply"]
  }
  state_bucket  = "arn:aws:s3:::${var.state_bucket}"
  state_objects = "arn:aws:s3:::${var.state_bucket}/${var.state_key_prefix}/*"
  legacy_states = var.legacy_state_bucket == "" ? [] : [{
    bucket  = "arn:aws:s3:::${var.legacy_state_bucket}"
    objects = "arn:aws:s3:::${var.legacy_state_bucket}/${var.legacy_state_key_prefix}/*"
    prefix  = "${var.legacy_state_key_prefix}/*"
  }]
}

# --- Shared state access (both roles read/write this repo's state) ------------
# use_lockfile stores the lock as an S3 object beside the state, so both roles
# need Put/Delete on the object prefix, not just Get. No DynamoDB table exists.
# State is SSE-KMS under the dedicated CMK, so both roles also need the key,
# and only through S3.
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
  statement {
    sid       = "UseStateKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.state.arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }

  # Legacy grant, off by default (SSE-S3 there, so no KMS). Only rendered when
  # legacy_state_bucket is set for a rollback.
  dynamic "statement" {
    for_each = local.legacy_states
    content {
      sid       = "ListLegacyStateBucket"
      actions   = ["s3:ListBucket"]
      resources = [statement.value.bucket]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = [statement.value.prefix]
      }
    }
  }
  dynamic "statement" {
    for_each = local.legacy_states
    content {
      sid       = "ReadWriteLegacyState"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = [statement.value.objects]
    }
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
  # checkov:skip=CKV_AWS_356:organizations:Describe*/List* and sts:GetCallerIdentity do not support resource-level scoping.
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
  # The governance root (terraform/) keeps the org trail, Identity Center, the
  # root-activity alert path, budgets and the detective-service admin delegation in
  # this account. Refreshing them needs configuration reads only: no kms:Decrypt,
  # no s3:GetObject outside state, no secret values.
  statement {
    sid = "ReadGovernanceConfig"
    actions = [
      "cloudtrail:Describe*", "cloudtrail:Get*", "cloudtrail:List*",
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListAliases", "kms:ListResourceTags",
      "sso:Describe*", "sso:Get*", "sso:List*",
      "identitystore:Describe*", "identitystore:Get*", "identitystore:List*",
      "budgets:View*", "budgets:ListTagsForResource",
      "ce:GetAnomalyMonitors", "ce:GetAnomalySubscriptions", "ce:ListTagsForResource",
      "sns:GetTopicAttributes", "sns:GetSubscriptionAttributes", "sns:ListSubscriptionsByTopic", "sns:ListTagsForResource",
      "events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource",
      "iam:GetAccountPasswordPolicy",
      "guardduty:ListOrganizationAdminAccounts",
      "securityhub:ListOrganizationAdminAccounts",
      "ram:GetResourceShareAssociations", "ram:ListResourceShares",
      # network/ingress.tf reads the jordandesigns.io zone to place the ingress
      # name and its ACM validation record.
      "route53:GetHostedZone", "route53:ListHostedZones", "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets", "route53:GetChange", "route53:ListTagsForResource",
      # Step 5: the member-recorder StackSet, the management Config recorder and
      # the Firewall Manager admin association (terraform/config-org.tf, fms.tf).
      "cloudformation:Describe*", "cloudformation:List*", "cloudformation:GetTemplate*",
      "config:Describe*", "config:Get*", "config:List*",
      "fms:GetAdminAccount", "fms:ListAdminAccountsForOrganization", "fms:ListTagsForResource",
    ]
    resources = ["*"]
  }
  statement {
    sid = "ReadManagementConfigRole"
    actions = [
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/lz-config-recorder"]
  }
  statement {
    sid       = "ChainToMemberPlanRoles"
    actions   = ["sts:AssumeRole"]
    resources = local.member_role_arns.plan
  }
  # The accounts/ root's aws_ram_sharing_with_organization refreshes by reading
  # RAM's service-linked role, so the scheduled drift check needs this one
  # GetRole. Scoped to that role alone.
  statement {
    sid       = "ReadRamServiceLinkedRole"
    actions   = ["iam:GetRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/ram.amazonaws.com/AWSServiceRoleForResourceAccessManager"]
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
# environments (prod-apply and destroy for the hourly stack, org-apply for the
# persistent accounts/ and terraform/ roots). The required reviewer on those environments is the JIT-to-prod
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
  # checkov:skip=CKV_AWS_111:Most organizations:* actions do not support resource-level scoping; the reviewer-gated environment is the control (see comment above).
  # checkov:skip=CKV_AWS_356:Same: organizations:* and sts:GetCallerIdentity cannot be scoped to resources.
  # checkov:skip=CKV_AWS_109:The governance root writes key policies, topic policies and Identity Center assignments for resources it creates, so their ARNs do not exist to scope to; the org-apply reviewer approving a saved plan is the constraint (ADR-0004 addendum).
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
  # The governance root's management-account resources (ADR-0004 addendum).
  # Bounded the same way as the org actions above: only the org-apply environment
  # reaches this role, and its reviewer approves the saved plan.
  statement {
    sid = "ManageGovernanceRoot"
    actions = [
      "cloudtrail:*",
      "kms:CreateKey", "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias", "kms:DescribeKey",
      "kms:EnableKeyRotation", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:PutKeyPolicy",
      "kms:ListAliases", "kms:ListResourceTags", "kms:TagResource", "kms:UntagResource",
      "sso:*", "identitystore:*",
      "budgets:*",
      "ce:*Anomaly*", "ce:TagResource", "ce:UntagResource", "ce:ListTagsForResource",
      "sns:*",
      "events:*",
      "iam:GetAccountPasswordPolicy", "iam:UpdateAccountPasswordPolicy",
      "guardduty:EnableOrganizationAdminAccount", "guardduty:DisableOrganizationAdminAccount", "guardduty:ListOrganizationAdminAccounts",
      "securityhub:EnableOrganizationAdminAccount", "securityhub:DisableOrganizationAdminAccount", "securityhub:ListOrganizationAdminAccounts",
      "ram:EnableSharingWithAwsOrganization", "ram:GetResourceShareAssociations", "ram:ListResourceShares",
      "iam:GetRole",
    ]
    resources = ["*"]
  }
  # Route 53 writes for the ingress DMZ (network/ingress.tf), limited to the
  # ingress hostname and its ACM validation record. The site's own records in
  # the same zone stay out of reach.
  statement {
    sid       = "ReadIngressZone"
    actions   = ["route53:GetHostedZone", "route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:ListResourceRecordSets", "route53:GetChange", "route53:ListTagsForResource"]
    resources = ["*"]
  }
  statement {
    sid       = "WriteIngressRecordsOnly"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/*"]
    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = [var.ingress_hostname, "_*.${var.ingress_hostname}"]
    }
  }
  # Step 5 writes in the management account: the member-recorder StackSet, the
  # management Config recorder and its one role, and the FMS admin association.
  statement {
    sid = "ManageOrgConfigAndFms"
    actions = [
      "cloudformation:CreateStackSet", "cloudformation:UpdateStackSet", "cloudformation:DeleteStackSet",
      "cloudformation:CreateStackInstances", "cloudformation:UpdateStackInstances", "cloudformation:DeleteStackInstances",
      "cloudformation:Describe*", "cloudformation:List*", "cloudformation:GetTemplate*",
      "cloudformation:TagResource", "cloudformation:UntagResource",
      "config:PutConfigurationRecorder", "config:PutDeliveryChannel", "config:StartConfigurationRecorder",
      "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
      "config:Describe*", "config:Get*", "config:List*",
      "fms:AssociateAdminAccount", "fms:DisassociateAdminAccount", "fms:GetAdminAccount",
      "fms:ListAdminAccountsForOrganization",
    ]
    resources = ["*"]
  }
  statement {
    sid = "ManageManagementConfigRole"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole", "iam:TagRole", "iam:UntagRole",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/lz-config-recorder"]
  }
  statement {
    sid       = "PassConfigRoleToConfig"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/lz-config-recorder"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["config.amazonaws.com"]
    }
  }
  # The CI role never schedules a key for deletion or hands the trail key away;
  # those stay operator actions.
  statement {
    sid       = "NoKeyDestruction"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
    resources = ["*"]
  }
  statement {
    sid       = "ChainToMemberApplyRoles"
    actions   = ["sts:AssumeRole"]
    resources = local.member_role_arns.apply
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
