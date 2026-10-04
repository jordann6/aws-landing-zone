# Organization CloudTrail delivered to an immutable bucket in the log-archive
# account. Every account in the org writes here; nothing in the org can read or
# tamper with it (the deny-cloudtrail-tampering SCP plus Object Lock). This is the
# record you reach for after an incident, so it must survive the account that
# generated it being compromised.

locals {
  trail_bucket_name = "org-cloudtrail-logs-${local.log_archive_account_id}"
}

resource "aws_s3_bucket" "trail" {
  provider = aws.log_archive
  #checkov:skip=CKV_AWS_18:Access logging on the log bucket itself is recursive; the trail is the log of record.
  #checkov:skip=CKV_AWS_144:Cross-region replication of the trail is a Phase-5 concern (backup/DR), not this layer.
  #checkov:skip=CKV2_AWS_62:Event notifications are not part of the demo; findings flow via Security Hub/GuardDuty.

  bucket = local.trail_bucket_name

  # Object Lock (WORM) is set at creation. force_destroy lets the demo tear down;
  # see the teardown note in the Makefile for governance-retained objects.
  object_lock_enabled = true
  force_destroy       = true

  tags = { Name = local.trail_bucket_name }
}

resource "aws_s3_bucket_versioning" "trail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.trail.id
  versioning_configuration {
    status = "Enabled"
  }
}

# GOVERNANCE, not COMPLIANCE: production would use COMPLIANCE for true
# irreversibility, but that would also make the bucket un-destroyable for the
# retention window, which breaks the deploy/demo/destroy posture. GOVERNANCE
# demonstrates WORM while letting a privileged teardown bypass it.
resource "aws_s3_bucket_object_lock_configuration" "trail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.trail.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.trail_lock_retention_days
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logging.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.trail.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.trail.id

  rule {
    id     = "expire-noncurrent-and-cleanup"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "trail_bucket" {
  # CloudTrail checks the bucket ACL before it writes.
  statement {
    sid       = "CloudTrailGetBucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${local.management_account_id}:trail/${var.trail_name}"]
    }
  }

  # CloudTrail writes member-account logs under the org-id prefix, and the
  # management account's own logs (and the CreateTrail validation object) under
  # its account-id prefix. An org trail needs both paths or CreateTrail fails.
  statement {
    sid     = "CloudTrailPutOrgObjects"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.trail.arn}/AWSLogs/${local.org_id}/*",
      "${aws_s3_bucket.trail.arn}/AWSLogs/${local.management_account_id}/*",
    ]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${var.region}:${local.management_account_id}:trail/${var.trail_name}"]
    }
  }

  # No plaintext path to the audit record.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.trail.id
  policy   = data.aws_iam_policy_document.trail_bucket.json
}

# The organization trail itself lives in the management account. is_organization_trail
# fans it out to every member account automatically, including accounts created later.
resource "aws_cloudtrail" "org" {
  #checkov:skip=CKV2_AWS_10:CloudWatch Logs alerting integration is deferred; detection is via GuardDuty + Security Hub CIS.
  #checkov:skip=CKV_AWS_252:No SNS topic in the demo; the trail is validated and KMS-encrypted, which is the audit requirement.
  name           = var.trail_name
  s3_bucket_name = aws_s3_bucket.trail.id

  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.logging.arn

  depends_on = [
    aws_s3_bucket_policy.trail,
  ]
}
