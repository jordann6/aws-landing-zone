# Forensics target roles in prod. The runbook runs in the security account (the
# GuardDuty delegated admin, where findings land); every step that touches a
# workload assumes its own role here. One role per step keeps the runbook's
# per-function least privilege across the account boundary: the snapshot step
# cannot revoke, the revoke step cannot touch EC2, and each role trusts exactly
# its own security-account Lambda role, inside this organization.

locals {
  forensics_role_path = "/forensics/"

  # Evidence key in the security account, matched by alias so this root does not
  # depend on the forensics stack's apply order. The key policy there is the real
  # fence: it grants only the encrypt step's target role.
  forensics_key_alias = "alias/${var.forensics_prefix}-evidence"
  security_keys_arn   = "arn:aws:kms:${var.region}:${local.security_account_id}:key/*"

  region_condition = {
    test     = "StringEquals"
    variable = "aws:RequestedRegion"
    values   = [var.region]
  }

  # Step names match the forensics Lambdas. The map is heterogeneous (statements
  # differ per step), so resources iterate over its keys.
  forensics_steps = {
    extract-context = {
      statements = [
        { sid = "Describe", actions = ["ec2:DescribeInstances"], resources = ["*"], conditions = [] },
      ]
    }
    isolate-instance = {
      statements = [
        {
          sid        = "Describe"
          actions    = ["ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSecurityGroups"]
          resources  = ["*"]
          conditions = []
        },
        {
          sid        = "SwapGroupsAndTag"
          actions    = ["ec2:ModifyNetworkInterfaceAttribute", "ec2:CreateTags"]
          resources  = ["*"]
          conditions = [local.region_condition]
        },
      ]
    }
    snapshot-evidence = {
      statements = [
        { sid = "Describe", actions = ["ec2:DescribeInstances", "ec2:DescribeVolumes"], resources = ["*"], conditions = [] },
        {
          sid        = "Snapshot"
          actions    = ["ec2:CreateSnapshot", "ec2:CreateTags"]
          resources  = ["*"]
          conditions = [local.region_condition]
        },
      ]
    }
    encrypt-snapshots = {
      statements = [
        { sid = "Describe", actions = ["ec2:DescribeSnapshots"], resources = ["*"], conditions = [] },
        {
          sid        = "Copy"
          actions    = ["ec2:CopySnapshot", "ec2:CreateTags"]
          resources  = ["*"]
          conditions = [local.region_condition]
        },
        {
          # The source snapshot's key (prod EBS CMK) already allows any principal
          # in this account through EC2, so only the evidence key is named here.
          sid = "EvidenceKey"
          actions = [
            "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*",
            "kms:DescribeKey", "kms:CreateGrant",
          ]
          resources = [local.security_keys_arn]
          conditions = [{
            test     = "ForAnyValue:StringEquals"
            variable = "kms:ResourceAliases"
            values   = [local.forensics_key_alias]
          }]
        },
      ]
    }
    check-snapshots = {
      statements = [
        { sid = "Describe", actions = ["ec2:DescribeSnapshots"], resources = ["*"], conditions = [] },
      ]
    }
    revoke-credentials = {
      statements = [
        {
          # The only mutation: an inline deny on roles under the revocable path.
          sid        = "RevokeUnderPath"
          actions    = ["iam:GetRole", "iam:PutRolePolicy"]
          resources  = ["arn:aws:iam::${local.prod_account_id}:role${var.revocable_role_path}*"]
          conditions = []
        },
      ]
    }
    collect-evidence = {
      statements = [
        {
          sid        = "Describe"
          actions    = ["ec2:DescribeInstances", "ec2:DescribeSnapshots", "ec2:GetConsoleOutput"]
          resources  = ["*"]
          conditions = []
        },
        {
          # Only the runbook's own unencrypted staging snapshots.
          sid       = "DeleteSourceSnapshots"
          actions   = ["ec2:DeleteSnapshot"]
          resources = ["arn:aws:ec2:${var.region}::snapshot/*"]
          conditions = [{
            test     = "StringEquals"
            variable = "aws:ResourceTag/forensics:stage"
            values   = ["source"]
          }]
        },
      ]
    }
  }
}

data "aws_iam_policy_document" "forensics_trust" {
  for_each = toset(keys(local.forensics_steps))

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.security_account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${local.security_account_id}:role/${var.forensics_prefix}-${each.key}"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [local.acct.organization_id]
    }
  }
}

data "aws_iam_policy_document" "forensics_step" {
  #checkov:skip=CKV_AWS_356:EC2 Describe* has no resource-level scoping; mutations are region- or tag-conditioned.
  #checkov:skip=CKV_AWS_111:Write actions are scoped by region, tag, or the revocable role path.
  for_each = toset(keys(local.forensics_steps))

  dynamic "statement" {
    for_each = local.forensics_steps[each.key].statements
    content {
      sid       = statement.value.sid
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.conditions
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role" "forensics" {
  for_each = toset(keys(local.forensics_steps))
  provider = aws.prod

  name               = "forensics-${each.key}"
  path               = local.forensics_role_path
  assume_role_policy = data.aws_iam_policy_document.forensics_trust[each.key].json
}

resource "aws_iam_role_policy" "forensics" {
  for_each = toset(keys(local.forensics_steps))
  provider = aws.prod

  name   = "forensics-${each.key}"
  role   = aws_iam_role.forensics[each.key].id
  policy = data.aws_iam_policy_document.forensics_step[each.key].json
}
