# Synthetic heartbeat producer. A scheduled Lambda writes one tiny object under
# heartbeat/ so the freshness check and the stale alarm can be proven. It does not
# show that a real backup ran or can be restored. Pause it with
# heartbeat_enabled = false to prove the stale direction.

locals {
  heartbeat_name      = "${local.name}-heartbeat"
  heartbeat_log_group = "/aws/lambda/${local.heartbeat_name}"
}

resource "aws_cloudwatch_log_group" "heartbeat" {
  #checkov:skip=CKV_AWS_338:30-day retention for a small operational log; a year is a production setting.
  provider = aws.monitoring

  name              = local.heartbeat_log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.backup.arn

  tags = { Name = "${local.heartbeat_name}-logs" }
}

data "aws_iam_policy_document" "heartbeat" {
  statement {
    sid       = "PutUnderTheHeartbeatPrefixOnly"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/${var.heartbeat_prefix}*"]
  }

  statement {
    sid       = "EncryptWithTheBucketKey"
    actions   = ["kms:GenerateDataKey"]
    resources = [aws_kms_key.backup.arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.heartbeat.arn}:*"]
  }
}

resource "aws_iam_role" "heartbeat" {
  provider = aws.monitoring

  name               = "${local.heartbeat_name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = { Name = "${local.heartbeat_name}-lambda" }
}

resource "aws_iam_role_policy" "heartbeat" {
  provider = aws.monitoring

  name   = "least-privilege"
  role   = aws_iam_role.heartbeat.id
  policy = data.aws_iam_policy_document.heartbeat.json
}

data "archive_file" "heartbeat" {
  type        = "zip"
  source_file = "${path.module}/lambda/heartbeat.py"
  output_path = "${path.module}/heartbeat.zip"
}

resource "aws_lambda_function" "heartbeat" {
  #checkov:skip=CKV_AWS_115:The account Lambda concurrency quota is 10, and a reservation would drop unreserved concurrency below the minimum of 10. A duplicate run only writes one more tiny object.
  #checkov:skip=CKV_AWS_117:The function only calls AWS APIs and holds no data; a VPC adds NAT cost for no isolation gain.
  #checkov:skip=CKV_AWS_116:A failed run surfaces as a stale object on the freshness alarm; a DLQ adds nothing.
  #checkov:skip=CKV_AWS_272:Code signing adds a signing pipeline for one 30-line function in a sandbox-scale account.
  provider = aws.monitoring

  function_name    = local.heartbeat_name
  role             = aws_iam_role.heartbeat.arn
  runtime          = "python3.13"
  handler          = "heartbeat.lambda_handler"
  filename         = data.archive_file.heartbeat.output_path
  source_code_hash = data.archive_file.heartbeat.output_base64sha256
  timeout          = 30
  memory_size      = 128
  kms_key_arn      = aws_kms_key.backup.arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      BUCKET_NAME      = aws_s3_bucket.backups.bucket
      HEARTBEAT_PREFIX = var.heartbeat_prefix
      KMS_KEY_ARN      = aws_kms_key.backup.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.heartbeat, aws_iam_role_policy.heartbeat]

  tags = { Name = local.heartbeat_name }
}

resource "aws_cloudwatch_event_rule" "heartbeat" {
  provider = aws.monitoring

  name                = local.heartbeat_name
  description         = "Write a synthetic heartbeat object every ${var.heartbeat_every_hours} hours"
  schedule_expression = "rate(${var.heartbeat_every_hours} hours)"
  state               = var.heartbeat_enabled ? "ENABLED" : "DISABLED"

  tags = { Name = local.heartbeat_name }
}

resource "aws_cloudwatch_event_target" "heartbeat" {
  provider = aws.monitoring

  rule      = aws_cloudwatch_event_rule.heartbeat.name
  target_id = "heartbeat"
  arn       = aws_lambda_function.heartbeat.arn
}

resource "aws_lambda_permission" "heartbeat_events" {
  provider = aws.monitoring

  statement_id  = "AllowSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heartbeat.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.heartbeat.arn
}
