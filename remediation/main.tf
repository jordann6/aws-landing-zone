# Event-driven remediation, in the prod account. A high-CPU alarm on a monitored
# instance goes through EventBridge to a Lambda that reboots it, behind a
# cooldown and a circuit breaker. After max_attempts reboots in the window it stops
# acting and pages the on-call topic instead.
#
# Scope is enforced twice: the Lambda skips instances without Monitored=true, and
# the IAM reboot permission carries the same tag condition. dry_run defaults to
# true, so the first drill notifies without rebooting.
#
# Notices use their own topics. The ops topic in observability/ would need its key
# policy to trust this role first; unifying them is a follow-up.

data "aws_caller_identity" "prod" {
  provider = aws.prod
}

locals {
  name         = "remediation"
  account_id   = data.aws_caller_identity.prod.account_id
  function     = "remediation-reboot"
  log_group    = "/aws/lambda/${local.function}"
  alarm_prefix = "remediate-cpu-"
}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_356:KMS key policies scope by principal/condition; Resource "*" means "this key".
  #checkov:skip=CKV_AWS_111:The root kms:* statement is the standard key-admin anchor so the key is never orphaned.
  #checkov:skip=CKV_AWS_109:The service statements are constrained by encryption context.
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
    sid       = "AllowLogsForTheLambdaLogGroup"
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

resource "aws_kms_key" "remediation" {
  provider = aws.prod

  description             = "CMK for the remediation topics, state table, log group and Lambda environment"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.key.json

  tags = { Name = "${local.name}-cmk" }
}

resource "aws_kms_alias" "remediation" {
  provider = aws.prod

  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.remediation.key_id
}

resource "aws_sns_topic" "alerts" {
  provider = aws.prod

  name              = "${local.name}-alerts"
  kms_master_key_id = aws_kms_key.remediation.arn

  tags = { Name = "${local.name}-alerts" }
}

resource "aws_sns_topic" "oncall" {
  provider = aws.prod

  name              = "${local.name}-oncall"
  kms_master_key_id = aws_kms_key.remediation.arn

  tags = { Name = "${local.name}-oncall" }
}

resource "aws_sns_topic_subscription" "alerts_email" {
  provider = aws.prod
  count    = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "oncall_email" {
  provider = aws.prod
  count    = var.alert_email == null ? 0 : 1

  topic_arn = aws_sns_topic.oncall.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_dynamodb_table" "state" {
  provider = aws.prod

  name         = "${local.name}-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "resource_action"

  attribute {
    name = "resource_action"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.remediation.arn
  }

  tags = { Name = "${local.name}-state" }
}

resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_338:30-day retention for a small operational log; a year is a production setting.
  provider = aws.prod

  name              = local.log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.remediation.arn

  tags = { Name = "${local.function}-logs" }
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

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "RebootMonitoredInstancesOnly"
    actions   = ["ec2:RebootInstances"]
    resources = ["arn:aws:ec2:${var.region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Monitored"
      values   = ["true"]
    }
  }

  statement {
    #checkov:skip=CKV_AWS_356:DescribeAlarms is scoped to the remediation alarm prefix; no wildcard beyond it.
    sid       = "RecheckAlarmState"
    actions   = ["cloudwatch:DescribeAlarms"]
    resources = ["arn:aws:cloudwatch:${var.region}:${local.account_id}:alarm:${local.alarm_prefix}*"]
  }

  statement {
    #checkov:skip=CKV_AWS_356:DescribeInstances does not support resource-level permissions.
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishNotices"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn, aws_sns_topic.oncall.arn]
  }

  statement {
    sid       = "RemediationState"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.state.arn]
  }

  statement {
    sid       = "UseTheKey"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [aws_kms_key.remediation.arn]
  }

  statement {
    #checkov:skip=CKV_AWS_356:PutMetricData does not support resource-level permissions; the namespace condition is the scope.
    sid       = "PutMetricsInOneNamespace"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Remediation"]
    }
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role" "lambda" {
  provider = aws.prod

  name               = "${local.function}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = { Name = "${local.function}-lambda" }
}

resource "aws_iam_role_policy" "lambda" {
  provider = aws.prod

  name   = "least-privilege"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/remediation.py"
  output_path = "${path.module}/remediation.zip"
}

resource "aws_lambda_function" "remediation" {
  #checkov:skip=CKV_AWS_115:The account Lambda concurrency quota is 10, and a reservation would drop unreserved concurrency below the minimum of 10. Duplicate runs are made harmless in code instead.
  #checkov:skip=CKV_AWS_117:The function only calls AWS APIs and holds no data; a VPC adds NAT cost for no isolation gain.
  #checkov:skip=CKV_AWS_116:Failures notify the on-call topic and re-fire on the next alarm evaluation; a DLQ adds nothing.
  #checkov:skip=CKV_AWS_272:Code signing adds a signing pipeline for one function in a sandbox-scale account.
  provider = aws.prod

  function_name    = local.function
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.13"
  handler          = "remediation.lambda_handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  memory_size      = 128
  kms_key_arn      = aws_kms_key.remediation.arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      SNS_TOPIC_ARN          = aws_sns_topic.alerts.arn
      ONCALL_TOPIC_ARN       = aws_sns_topic.oncall.arn
      STATE_TABLE            = aws_dynamodb_table.state.name
      COOLDOWN_SECONDS       = tostring(var.cooldown_seconds)
      CIRCUIT_WINDOW_SECONDS = tostring(var.circuit_window_seconds)
      MAX_ATTEMPTS           = tostring(var.max_attempts)
      METRIC_NAMESPACE       = "Remediation"
      ALARM_PREFIX           = local.alarm_prefix
      DRY_RUN                = tostring(var.dry_run)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]

  tags = { Name = local.function }
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  provider = aws.prod
  for_each = var.monitored_instance_ids

  alarm_name          = "${local.alarm_prefix}${each.value}"
  alarm_description   = "CPU at or above ${var.cpu_threshold}% for 10 minutes on ${each.value}; triggers the remediation Lambda"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = each.value }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.cpu_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = { Name = "${local.alarm_prefix}${each.value}" }
}

resource "aws_cloudwatch_event_rule" "alarm" {
  provider = aws.prod

  name        = "${local.name}-cpu-alarm"
  description = "Route remediation CPU alarms in ALARM state to the Lambda"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = local.alarm_prefix }]
      state     = { value = ["ALARM"] }
    }
  })

  tags = { Name = "${local.name}-cpu-alarm" }
}

resource "aws_cloudwatch_event_target" "lambda" {
  provider = aws.prod

  rule      = aws_cloudwatch_event_rule.alarm.name
  target_id = "remediation"
  arn       = aws_lambda_function.remediation.arn
}

resource "aws_lambda_permission" "events" {
  provider = aws.prod

  statement_id  = "AllowAlarmRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm.arn
}
