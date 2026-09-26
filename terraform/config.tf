# AWS Config in the security account. Security Hub's CIS checks read Config's
# recorded state, so this is what turns the standard from "subscribed" into
# "scored". Config delivers to its own bucket in the log-archive account.
#
# Demo scope: the recorder runs in the security (delegated-admin) account. A
# production rollout enables a recorder in every member account via a
# CloudFormation StackSet or Config's org rules; that is called out in
# docs/cis-mapping.md rather than pretended here.

locals {
  config_bucket_name = "org-config-${aws_organizations_account.log_archive.id}"
}

resource "aws_s3_bucket" "config" {
  provider = aws.log_archive
  #checkov:skip=CKV_AWS_18:Access logging on the log bucket itself is recursive.
  #checkov:skip=CKV_AWS_144:Cross-region replication of Config snapshots is out of scope for the demo.
  #checkov:skip=CKV2_AWS_62:Event notifications not used; findings flow via Security Hub.
  #checkov:skip=CKV_AWS_145:SSE-S3 by design here to avoid a cross-account KMS grant for the Config delivery role; CMK is the production upgrade.
  bucket        = local.config_bucket_name
  force_destroy = true
  tags          = { Name = local.config_bucket_name }
}

#trivy:ignore:AVD-AWS-0132:SSE-S3 by design here to avoid a cross-account KMS grant for the Config delivery role; CMK is the production upgrade.
resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 in the demo to avoid a cross-account KMS grant for the Config
      # delivery role; production would use the logging CMK.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  provider                = aws.log_archive
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id

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

data "aws_iam_policy_document" "config_bucket" {
  statement {
    sid       = "ConfigBucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.config.arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [aws_organizations_account.security.id]
    }
  }

  statement {
    sid       = "ConfigBucketPut"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${aws_organizations_account.security.id}/Config/*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [aws_organizations_account.security.id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
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

resource "aws_s3_bucket_policy" "config" {
  provider = aws.log_archive
  bucket   = aws_s3_bucket.config.id
  policy   = data.aws_iam_policy_document.config_bucket.json
}

# --- Config service role (security account) ---------------------------------
data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  provider           = aws.security
  name               = "aws-config-recorder"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  provider   = aws.security
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_delivery" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${aws_organizations_account.security.id}/Config/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
  }
}

resource "aws_iam_role_policy" "config_delivery" {
  provider = aws.security
  name     = "config-s3-delivery"
  role     = aws_iam_role.config.id
  policy   = data.aws_iam_policy_document.config_delivery.json
}

# --- Recorder + delivery channel --------------------------------------------
resource "aws_config_configuration_recorder" "security" {
  provider = aws.security
  name     = "org-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "security" {
  provider       = aws.security
  name           = "org-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  depends_on = [
    aws_config_configuration_recorder.security,
    aws_s3_bucket_policy.config,
  ]
}

resource "aws_config_configuration_recorder_status" "security" {
  provider   = aws.security
  name       = aws_config_configuration_recorder.security.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.security]
}

# A small conformance pack proving the pattern; production would use the full
# Operational Best Practices for CIS template.
resource "aws_config_conformance_pack" "baseline" {
  provider = aws.security
  name     = "cis-baseline"

  template_body = <<-YAML
    Resources:
      S3PublicReadProhibited:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: s3-bucket-public-read-prohibited
          Source:
            Owner: AWS
            SourceIdentifier: S3_BUCKET_PUBLIC_READ_PROHIBITED
      EncryptedVolumes:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: encrypted-volumes
          Source:
            Owner: AWS
            SourceIdentifier: ENCRYPTED_VOLUMES
      IamUserMfaEnabled:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: iam-user-mfa-enabled
          Source:
            Owner: AWS
            SourceIdentifier: IAM_USER_MFA_ENABLED
  YAML

  depends_on = [aws_config_configuration_recorder_status.security]
}
