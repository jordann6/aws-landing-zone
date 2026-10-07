# Compute baseline, account-level defaults for the prod account. These make the
# secure setting the default for every launch path (console, CLI, Terraform, the
# EKS node group's Auto Scaling group, and Image Builder), so a launch that never
# mentions encryption or IMDS still gets both. The org SCPs and the EC2
# declarative policy are the deny layer; these are the default layer.

data "aws_caller_identity" "prod" {}

locals {
  # o-xxxxxxxxxx from arn:aws:organizations::<mgmt>:organization/o-xxxxxxxxxx
  organization_id = var.organization_arn == null ? null : element(split("/", var.organization_arn), 1)
}

# Dedicated CMK for EBS. It is not gated on enable_rds like the data key, because
# the management instance and golden AMI snapshots need it even in a compute-only
# session.
data "aws_iam_policy_document" "ebs_key" {
  #checkov:skip=CKV_AWS_111:KMS key policy; Resource "*" means this key only, and the admin statement is the account-root delegation every CMK needs.
  #checkov:skip=CKV_AWS_356:KMS key policy; Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_109:KMS key policy; account-root kms:* is the standard delegation to IAM, and the wildcard-principal statement is bounded by CallerAccount (or PrincipalOrgID) plus ViaService ec2.
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.prod.account_id}:root"]
    }
  }

  # Same shape as the AWS-managed aws/ebs key: any principal in this account may
  # use the key, but only through EC2. This covers the Auto Scaling and Image
  # Builder service-linked roles without naming them, so the policy does not
  # fail validation in an account where they do not exist yet.
  statement {
    sid = "UseThroughEc2InThisAccount"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.prod.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.region}.amazonaws.com"]
    }
  }

  # Org members may launch the shared golden AMI, which needs its snapshot key.
  dynamic "statement" {
    for_each = local.organization_id == null ? [] : [local.organization_id]
    content {
      sid = "UseSharedGoldenAmiInOrg"
      actions = [
        "kms:Decrypt",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:DescribeKey",
        "kms:CreateGrant",
      ]
      resources = ["*"]
      principals {
        type        = "AWS"
        identifiers = ["*"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalOrgID"
        values   = [statement.value]
      }
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["ec2.${var.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_kms_key" "ebs" {
  description             = "Prod EBS default encryption (volumes, golden AMI snapshots)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.ebs_key.json
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/prod-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}

# Default EBS encryption itself is NOT managed here. The Workloads OU declarative
# policy (accounts/compute-baseline.tf) turns it on, and the require-encrypted-ebs
# SCP denies ec2:DisableEbsEncryptionByDefault, so an account-level resource could
# never be destroyed (the live run's workload destroy failed on it). Only the
# default KMS key below is set per account.

resource "aws_ebs_default_kms_key" "this" {
  key_arn = aws_kms_key.ebs.arn
}

# Hop limit 1: a container on a node cannot reach IMDS through the extra network
# hop, so it cannot read the node role. Pods use IRSA instead. The Workloads OU
# declarative policy (accounts/compute-baseline.tf) sets the same defaults and
# owns the attribute once attached, so this account-level copy is off by default.
resource "aws_ec2_instance_metadata_defaults" "this" {
  count = var.manage_instance_metadata_defaults ? 1 : 0

  http_tokens                 = "required"
  http_put_response_hop_limit = 1
  http_endpoint               = "enabled"
  instance_metadata_tags      = "disabled"
}
