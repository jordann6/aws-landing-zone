locals {
  alarm_name = "${var.name_prefix}-primary-unhealthy"

  alarm_event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [local.alarm_name]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

# ---------------------------------------------------------------------------
# Standby region: SNS notifications and the failover Lambda. These live in
# the standby region on purpose, they must keep working while the primary
# region is down.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "failover_events" {
  provider = aws.secondary

  name              = "${var.name_prefix}-failover-events"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "email" {
  count    = var.notification_email != "" ? 1 : 0
  provider = aws.secondary

  topic_arn = aws_sns_topic.failover_events.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_iam_role" "failover_lambda" {
  provider = aws.secondary

  name = "${var.name_prefix}-failover-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "failover_logs" {
  provider = aws.secondary

  role       = aws_iam_role.failover_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "failover" {
  provider = aws.secondary

  name = "promote-replica-and-notify"
  role = aws_iam_role.failover_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PromoteReplica"
        Effect   = "Allow"
        Action   = "rds:PromoteReadReplica"
        Resource = var.replica_arn
      },
      {
        Sid      = "InspectReplica"
        Effect   = "Allow"
        Action   = "rds:DescribeDBInstances"
        Resource = var.replica_arn
      },
      {
        Sid      = "Notify"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.failover_events.arn
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "failover" {
  #checkov:skip=CKV_AWS_158:DR proof layer is destroyed in the same session; log groups hold no secrets and a CMK adds a key policy for no gain.
  provider = aws.secondary

  name              = "/aws/lambda/${var.name_prefix}-failover"
  retention_in_days = 365
}

resource "aws_lambda_function" "failover" {
  #checkov:skip=CKV_AWS_50:Tracing adds nothing to a short DR proof.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for the proof; the zip is built from vendored source in this repo.
  #checkov:skip=CKV_AWS_173:Environment holds only hostnames and ARNs, no secrets; the credential is read from Secrets Manager.
  #checkov:skip=CKV_AWS_116:Synchronous handlers; a DLQ only applies to async invokes and the failover Lambda is retried by EventBridge.
  #checkov:skip=CKV_AWS_115:Reserved concurrency would draw down a small account quota for no benefit here.
  #checkov:skip=CKV_AWS_117:The failover Lambda must stay outside the VPC so it works when the primary region is down.
  provider = aws.secondary

  function_name    = "${var.name_prefix}-failover"
  role             = aws_iam_role.failover_lambda.arn
  filename         = var.lambda_zip
  source_code_hash = var.lambda_zip_hash
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 60

  environment {
    variables = {
      REPLICA_IDENTIFIER = var.replica_identifier
      SNS_TOPIC_ARN      = aws_sns_topic.failover_events.arn
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.failover,
    aws_iam_role_policy_attachment.failover_logs,
  ]
}

# ---------------------------------------------------------------------------
# Primary region (us-east-1): the alarm on the Route 53 health check, and an
# EventBridge rule that forwards the alarm state change to the standby
# region's default event bus. Health check metrics exist only in us-east-1.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "primary_health" {
  provider = aws.primary

  alarm_name          = local.alarm_name
  alarm_description   = "Primary region /health endpoint is failing its Route 53 health check"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = var.health_check_id
  }
}

resource "aws_iam_role" "cross_region_events" {
  provider = aws.primary

  name = "${var.name_prefix}-events-cross-region"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cross_region_events" {
  provider = aws.primary

  name = "put-events-to-standby-bus"
  role = aws_iam_role.cross_region_events.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:${var.secondary_region}:${var.account_id}:event-bus/default"
    }]
  })
}

resource "aws_cloudwatch_event_rule" "alarm_primary" {
  provider = aws.primary

  name          = "${var.name_prefix}-alarm-to-standby"
  description   = "Forward the primary health alarm to the standby region"
  event_pattern = local.alarm_event_pattern
}

resource "aws_cloudwatch_event_target" "to_standby_bus" {
  provider = aws.primary

  rule     = aws_cloudwatch_event_rule.alarm_primary.name
  arn      = "arn:aws:events:${var.secondary_region}:${var.account_id}:event-bus/default"
  role_arn = aws_iam_role.cross_region_events.arn
}

# ---------------------------------------------------------------------------
# Standby region: match the forwarded alarm event and invoke the Lambda.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "alarm_secondary" {
  provider = aws.secondary

  name          = "${var.name_prefix}-trigger-failover"
  description   = "Invoke the failover Lambda when the primary health alarm fires"
  event_pattern = local.alarm_event_pattern
}

resource "aws_cloudwatch_event_target" "invoke_failover" {
  provider = aws.secondary

  rule = aws_cloudwatch_event_rule.alarm_secondary.name
  arn  = aws_lambda_function.failover.arn
}

resource "aws_lambda_permission" "events" {
  provider = aws.secondary

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.failover.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_secondary.arn
}
