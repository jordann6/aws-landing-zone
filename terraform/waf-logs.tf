# Central destination for AWS WAF logs, in log-archive beside the org trail and
# Config history. The web ACL lives in the network account (network/ingress.tf)
# and writes here across accounts through the vended-logs service principal,
# the pattern AWS documents for centralized WAF logging.
#
# The bucket is persistent like the rest of this root, so it costs nothing while
# the hourly stack is down and keeps every WAF record after a teardown. AWS WAF
# requires the aws-waf-logs- name prefix.

locals {
  waf_log_bucket = "aws-waf-logs-${local.log_archive_account_id}"
  # Only the network account's log delivery may write here.
  waf_log_sources = compact([try(local.acct.network_account_id, null)])
}

resource "aws_s3_bucket" "waf_logs" {
  #checkov:skip=CKV_AWS_18:Access logging on a log bucket is recursive.
  #checkov:skip=CKV_AWS_144:Cross-region replication of WAF logs is out of scope for the demo.
  #checkov:skip=CKV2_AWS_62:Event notifications not used; WAF blocks surface through the web ACL's CloudWatch metrics.
  #checkov:skip=CKV_AWS_145:SSE-S3 by design, matching the Config bucket: a CMK would need a cross-account grant to the log delivery service; CMK is the production upgrade.
  provider = aws.log_archive
  bucket   = local.waf_log_bucket
}

resource "aws_s3_bucket_versioning" "waf_logs" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.waf_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132:SSE-S3 by design, matching the Config bucket; a CMK would need a cross-account grant to the log delivery service. CMK is the production upgrade.
resource "aws_s3_bucket_server_side_encryption_configuration" "waf_logs" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.waf_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "waf_logs" {
  provider                = aws.log_archive
  bucket                  = aws_s3_bucket.waf_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "waf_logs" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.waf_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "waf_logs" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.waf_logs.id

  rule {
    id     = "expire-waf-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "waf_logs" {
  statement {
    sid       = "AWSLogDeliveryWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.waf_logs.arn}/AWSLogs/*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = local.waf_log_sources
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [for id in local.waf_log_sources : "arn:aws:logs:${var.region}:${id}:*"]
    }
  }

  statement {
    sid       = "AWSLogDeliveryAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.waf_logs.arn]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = local.waf_log_sources
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [for id in local.waf_log_sources : "arn:aws:logs:${var.region}:${id}:*"]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.waf_logs.arn,
      "${aws_s3_bucket.waf_logs.arn}/*",
    ]
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
}

resource "aws_s3_bucket_policy" "waf_logs" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.waf_logs.id
  policy   = data.aws_iam_policy_document.waf_logs.json

  depends_on = [aws_s3_bucket_public_access_block.waf_logs]
}

output "waf_log_bucket_arn" {
  description = "Cross-account destination for the network account's WAF logs"
  value       = aws_s3_bucket.waf_logs.arn
}
