# Dedicated Terraform state backend for this repo (ADR-0003). Every root's
# backend block and every terraform_remote_state read points here. The bucket is
# created by bootstrap while bootstrap's own state still lives in the legacy
# shared bucket; scripts/migrate-state-backend.sh then copies every root's state
# in, bootstrap included.

data "aws_caller_identity" "current" {}

locals {
  state_bucket_arn = "arn:aws:s3:::${var.state_bucket}"
}

# --- Customer-managed key ----------------------------------------------------
data "aws_iam_policy_document" "state_key" {
  # checkov:skip=CKV_AWS_109:In a key policy, resource "*" means this key only; the root statement delegates to IAM policies, which scope it.
  # checkov:skip=CKV_AWS_111:Same: key policies cannot name the key ARN, so "*" is the key itself.
  # checkov:skip=CKV_AWS_356:Same: "*" in a key policy is the key, not every resource.
  # Standard root statement: lets IAM policies grant use of the key. Without it,
  # only principals named here could use the key, and the operator running the
  # migration (an IAM user, not a CI role) would hit AccessDenied on PutObject.
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # The CI roles may use the key only through S3 in this region, never directly.
  statement {
    sid       = "AllowCIRolesThroughS3"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.gha_plan.arn, aws_iam_role.gha_apply.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "state" {
  description             = "Terraform state for aws-landing-zone (bucket ${var.state_bucket})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.state_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = var.state_kms_alias
  target_key_id = aws_kms_key.state.key_id
}

# --- Bucket ------------------------------------------------------------------
# Access logging: same reason as the CKV_AWS_18 skip below.
#trivy:ignore:AVD-AWS-0089
resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_144:Cross-region replication is out of scope for a single-region lab; versioning plus prevent_destroy cover accidental loss.
  # checkov:skip=CKV_AWS_18:Server access logging would need a second log bucket for one low-traffic state bucket; revisit with CloudTrail S3 data events.
  # checkov:skip=CKV2_AWS_62:No consumer for event notifications on state objects.
  bucket = var.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyTLSBelow12"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.state_bucket_arn, "${local.state_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }

  # A backend with encrypt = true and no kms_key_id sends an explicit AES256
  # header, which overrides the bucket's KMS default. Refuse those writes so no
  # state object can land outside the CMK. Uploads without the header still get
  # the KMS default.
  statement {
    sid       = "DenySSES3Uploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${local.state_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "state-history"
    status = "Enabled"
    filter {}

    # A noncurrent version expires only once 20 newer versions exist AND it is
    # older than 90 days, so recent history is never thinned.
    noncurrent_version_expiration {
      newer_noncurrent_versions = 20
      noncurrent_days           = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}
