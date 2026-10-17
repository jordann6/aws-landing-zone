# Website uptime monitor, in the monitoring account (shared-services). EventBridge
# runs a Lambda every five minutes; it writes metrics and a DynamoDB log row. The
# alarms notify the central ops topic from the observability/ root, so website
# alerts land in the same inbox as the rest of the landing zone.
#
# Missing data is treated as breaching on the health alarm: if the checker stops
# running, the alarm fires instead of going quiet.

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
  name       = "uptime-monitor"
  ops_topic  = data.terraform_remote_state.observability.outputs.ops_topic_arn
  account_id = data.aws_caller_identity.monitoring.account_id
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

resource "aws_kms_key" "uptime" {
  provider = aws.monitoring

  description             = "CMK for the uptime monitor log table, log group and Lambda environment"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.key.json

  tags = { Name = "${local.name}-cmk" }
}

resource "aws_kms_alias" "uptime" {
  provider = aws.monitoring

  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.uptime.key_id
}

resource "aws_dynamodb_table" "logs" {
  provider = aws.monitoring

  name         = "${local.name}-logs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "check_id"
  range_key    = "timestamp"

  attribute {
    name = "check_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.uptime.arn
  }

  tags = { Name = "${local.name}-logs" }
}

resource "aws_cloudwatch_log_group" "checker" {
  #checkov:skip=CKV_AWS_338:30-day retention for a small operational log; a year is a production setting.
  provider = aws.monitoring

  name              = local.log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.uptime.arn

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
    sid       = "WriteCheckLog"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.logs.arn]
  }

  statement {
    sid       = "UseTheKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.uptime.arn]
  }

  statement {
    #checkov:skip=CKV_AWS_356:PutMetricData does not support resource-level permissions; the namespace condition is the scope.
    sid       = "PutMetricsInOneNamespace"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["UptimeMonitor"]
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
  source_file = "${path.module}/lambda/uptime_checker.py"
  output_path = "${path.module}/uptime_checker.zip"
}

resource "aws_lambda_function" "checker" {
  #checkov:skip=CKV_AWS_115:The account Lambda concurrency quota is 10, and a reservation would drop unreserved concurrency below the minimum of 10. Duplicate runs are made harmless in code instead.
  #checkov:skip=CKV_AWS_117:The checker must reach a public website, so it runs outside a VPC; the role is least-privilege.
  #checkov:skip=CKV_AWS_116:A failed scheduled run is retried by the next run and surfaces as missing data on the health alarm; a DLQ adds nothing.
  #checkov:skip=CKV_AWS_272:Code signing adds a signing pipeline for one 100-line function in a sandbox-scale account.
  provider = aws.monitoring

  function_name    = local.name
  role             = aws_iam_role.checker.arn
  runtime          = "python3.13"
  handler          = "uptime_checker.lambda_handler"
  filename         = data.archive_file.checker.output_path
  source_code_hash = data.archive_file.checker.output_base64sha256
  timeout          = 30
  memory_size      = 128
  kms_key_arn      = aws_kms_key.uptime.arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      CHECK_URL        = var.check_url
      CONTENT_CHECK    = var.content_check
      TABLE_NAME       = aws_dynamodb_table.logs.name
      METRIC_NAMESPACE = "UptimeMonitor"
    }
  }

  depends_on = [aws_cloudwatch_log_group.checker, aws_iam_role_policy.checker]

  tags = { Name = local.name }
}

resource "aws_cloudwatch_event_rule" "schedule" {
  provider = aws.monitoring

  name                = "${local.name}-5min"
  description         = "Run the website check every 5 minutes"
  schedule_expression = "rate(5 minutes)"

  tags = { Name = "${local.name}-5min" }
}

resource "aws_cloudwatch_event_target" "checker" {
  provider = aws.monitoring

  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "checker"
  arn       = aws_lambda_function.checker.arn
}

resource "aws_lambda_permission" "events" {
  provider = aws.monitoring

  statement_id  = "AllowSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

resource "aws_cloudwatch_metric_alarm" "down" {
  provider = aws.monitoring

  alarm_name          = "${local.name}-site-down"
  alarm_description   = "${var.check_url} failed two consecutive checks, or the checker stopped reporting"
  namespace           = "UptimeMonitor"
  metric_name         = "IsHealthy"
  dimensions          = { URL = var.check_url }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [local.ops_topic]
  ok_actions          = [local.ops_topic]

  tags = { Name = "${local.name}-site-down" }
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  provider = aws.monitoring

  alarm_name          = "${local.name}-high-latency"
  alarm_description   = "${var.check_url} averaged over ${var.latency_threshold_ms} ms for three checks"
  namespace           = "UptimeMonitor"
  metric_name         = "LatencyMs"
  dimensions          = { URL = var.check_url }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.latency_threshold_ms
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ops_topic]
  ok_actions          = [local.ops_topic]

  tags = { Name = "${local.name}-high-latency" }
}

resource "aws_cloudwatch_metric_alarm" "certificate" {
  provider = aws.monitoring

  alarm_name          = "${local.name}-certificate-expiry"
  alarm_description   = "The certificate for ${var.check_url} has fewer than ${var.ssl_warn_days} days left"
  namespace           = "UptimeMonitor"
  metric_name         = "SSLDaysRemaining"
  dimensions          = { URL = var.check_url }
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = var.ssl_warn_days
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.ops_topic]
  ok_actions          = [local.ops_topic]

  tags = { Name = "${local.name}-certificate-expiry" }
}
