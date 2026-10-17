# Backup bucket plus a daily freshness check, in the monitoring account. The
# bucket is versioned, KMS-encrypted, tiered and never public. A scheduled Lambda
# reports the age of the newest object; an alarm on the ops topic fires when
# backups stop arriving (or when the check itself stops running).

data "terraform_remote_state" "observability" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/observability.tfstate"
    region = "us-east-1"
  }
}

data "aws_caller_identity" "monitoring" {
  provider = aws.monitoring
}

locals {
  name       = "backup-verify"
  ops_topic  = data.terraform_remote_state.observability.outputs.ops_topic_arn
  account_id = data.aws_caller_identity.monitoring.account_id
  bucket     = "lz-landing-${local.account_id}-${var.region}"
  log_group  = "/aws/lambda/${local.name}"
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_356:KMS key policies scope by principal/condition; Resource "*" means "this key".
  #checkov:skip=CKV_AWS_111:The root kms:* statement is the standard key-admin anchor so the key is never orphaned.
  #checkov:skip=CKV_AWS_109:The service statement is constrained by the log group encryption context.
  statement {
    sid       = "EnableRootPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowLogsForTheCheckerLogGroup"
    effect    = "Allow"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:${local.log_group}"]
    }
  }
}

resource "aws_kms_key" "backup" {
  provider = aws.monitoring

  description             = "CMK for the backup bucket, check log group and Lambda environment"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.key.json

  # The bucket's data is unreadable without this key, so it is protected too.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${local.name}-cmk" }
}

resource "aws_kms_alias" "backup" {
  provider = aws.monitoring

  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.backup.key_id
}

resource "aws_s3_bucket" "backups" {
  #checkov:skip=CKV_AWS_18:Access logging for a metadata-only demo bucket adds a second bucket; CloudTrail data events are the audit trail.
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope; the standby design covers the data tier.
  #checkov:skip=CKV2_AWS_62:No consumer needs object event notifications; freshness is polled.
  provider = aws.monitoring

  bucket = local.bucket

  # Standing landing bucket: terraform destroy fails here on purpose. Remove this
  # block, empty the bucket and destroy deliberately if it is ever retired.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = local.bucket }
}

resource "aws_s3_bucket_versioning" "backups" {
  provider = aws.monitoring

  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  provider = aws.monitoring

  bucket = aws_s3_bucket.backups.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  provider = aws.monitoring

  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.backups.arn, "${aws_s3_bucket.backups.arn}/*"]
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

resource "aws_s3_bucket_policy" "backups" {
  provider = aws.monitoring

  bucket     = aws_s3_bucket.backups.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.backups]
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  provider = aws.monitoring

  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = var.ia_after_days
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = var.glacier_after_days
      storage_class = "GLACIER"
    }
    dynamic "expiration" {
      for_each = var.expire_after_days == null ? [] : [var.expire_after_days]
      content {
        days = expiration.value
      }
    }
    noncurrent_version_transition {
      noncurrent_days = 7
      storage_class   = "GLACIER"
    }
    dynamic "noncurrent_version_expiration" {
      for_each = var.noncurrent_expire_days == null ? [] : [var.noncurrent_expire_days]
      content {
        noncurrent_days = noncurrent_version_expiration.value
      }
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_cloudwatch_log_group" "checker" {
  #checkov:skip=CKV_AWS_338:30-day retention for a small operational log; a year is a production setting.
  provider = aws.monitoring

  name              = local.log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.backup.arn

  tags = { Name = "${local.name}-logs" }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "checker" {
  statement {
    sid       = "ListTheBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "UseTheKey"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.backup.arn]
  }

  statement {
    #checkov:skip=CKV_AWS_356:PutMetricData does not support resource-level permissions; the namespace condition is the scope.
    sid       = "PutMetricsInOneNamespace"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["BackupVerify"]
    }
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.checker.arn}:*"]
  }
}

resource "aws_iam_role" "checker" {
  provider = aws.monitoring

  name               = "${local.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = { Name = "${local.name}-lambda" }
}

resource "aws_iam_role_policy" "checker" {
  provider = aws.monitoring

  name   = "least-privilege"
  role   = aws_iam_role.checker.id
  policy = data.aws_iam_policy_document.checker.json
}

data "archive_file" "checker" {
  type        = "zip"
  source_file = "${path.module}/lambda/backup_check.py"
  output_path = "${path.module}/backup_check.zip"
}

resource "aws_lambda_function" "checker" {
  #checkov:skip=CKV_AWS_117:The function only calls AWS APIs and holds no data; a VPC adds NAT cost for no isolation gain.
  #checkov:skip=CKV_AWS_116:A failed daily run surfaces as missing data on the freshness alarm; a DLQ adds nothing.
  #checkov:skip=CKV_AWS_272:Code signing adds a signing pipeline for one 40-line function in a sandbox-scale account.
  provider = aws.monitoring

  function_name                  = local.name
  role                           = aws_iam_role.checker.arn
  runtime                        = "python3.13"
  handler                        = "backup_check.lambda_handler"
  filename                       = data.archive_file.checker.output_path
  source_code_hash               = data.archive_file.checker.output_base64sha256
  timeout                        = 60
  memory_size                    = 128
  reserved_concurrent_executions = 1
  kms_key_arn                    = aws_kms_key.backup.arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      BUCKET_NAME      = aws_s3_bucket.backups.bucket
      METRIC_NAMESPACE = "BackupVerify"
    }
  }

  depends_on = [aws_cloudwatch_log_group.checker, aws_iam_role_policy.checker]

  tags = { Name = local.name }
}

resource "aws_cloudwatch_event_rule" "daily" {
  provider = aws.monitoring

  name                = "${local.name}-daily"
  description         = "Run the backup freshness check daily at 08:00 UTC"
  schedule_expression = "cron(0 8 * * ? *)"

  tags = { Name = "${local.name}-daily" }
}

resource "aws_cloudwatch_event_target" "checker" {
  provider = aws.monitoring

  rule      = aws_cloudwatch_event_rule.daily.name
  target_id = "checker"
  arn       = aws_lambda_function.checker.arn
}

resource "aws_lambda_permission" "events" {
  provider = aws.monitoring

  statement_id  = "AllowSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}

resource "aws_cloudwatch_metric_alarm" "stale" {
  provider = aws.monitoring
  count    = var.freshness_alarm_enabled ? 1 : 0

  alarm_name          = "${local.name}-stale-backup"
  alarm_description   = "Newest object in ${local.bucket} is older than ${var.max_age_hours} hours, or the check stopped reporting"
  namespace           = "BackupVerify"
  metric_name         = "NewestObjectAgeHours"
  dimensions          = { Bucket = local.bucket }
  statistic           = "Maximum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = var.max_age_hours
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [local.ops_topic]
  ok_actions          = [local.ops_topic]

  tags = { Name = "${local.name}-stale-backup" }
}
