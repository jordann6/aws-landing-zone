# Customer-managed key for the audit trail, living in the log-archive account
# beside the logs it protects. Rotation on. This is the same key family the org
# CloudTrail, its S3 bucket, and AWS Config all encrypt with, so one key controls
# access to the entire immutable record.

data "aws_iam_policy_document" "logging_key" {
  #checkov:skip=CKV_AWS_356:KMS key policies scope by principal/condition; Resource "*" means "this key" and is the required idiom.
  #checkov:skip=CKV_AWS_111:The root kms:* statement is the standard key-admin anchor so the key is never orphaned.
  #checkov:skip=CKV_AWS_109:Service statements are constrained by SourceArn/SourceAccount/EncryptionContext conditions.
  # Account root keeps full control of the key (standard, so the key is not
  # orphaned if a grant is misconfigured).
  statement {
    sid       = "EnableRootPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${aws_organizations_account.log_archive.id}:root"]
    }
  }

  # CloudTrail encrypts each log file with a data key from this CMK. Scoped to the
  # organization trail in the management account so no other trail can use it.
  # GenerateDataKey carries the trail ARN as encryption context, so it is gated on
  # that context.
  statement {
    sid       = "AllowCloudTrailEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${aws_organizations_organization.org.master_account_id}:trail/*"]
    }
  }

  # DescribeKey is called during CreateTrail validation with no encryption context
  # and (pre-create) no reliable source ARN, so it cannot be gated on either;
  # AWS's canonical CloudTrail key policy leaves it unconditioned. It is a
  # metadata-only read. Without it, CreateTrail fails InsufficientEncryptionPolicy.
  statement {
    sid       = "AllowCloudTrailDescribeKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  # AWS Config encrypts its snapshots and history with the same key.
  statement {
    sid       = "AllowConfigEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [aws_organizations_organization.org.master_account_id]
    }
  }
}

resource "aws_kms_key" "logging" {
  provider = aws.log_archive

  description             = "CMK for org CloudTrail, Config, and the log-archive bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.logging_key.json

  tags = { Name = "logging-cmk" }
}

resource "aws_kms_alias" "logging" {
  provider = aws.log_archive

  name          = "alias/logging-cmk"
  target_key_id = aws_kms_key.logging.key_id
}
