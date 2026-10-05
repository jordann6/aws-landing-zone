# Finding routing, in the security account. GuardDuty and Security Hub are both
# administered from here, so findings from every member account land on this
# account's default event bus. HIGH and CRITICAL findings go to one topic, which
# the forensics runbook (Phase D) and an optional email subscribe to.

data "aws_iam_policy_document" "findings_key" {
  #checkov:skip=CKV_AWS_356:KMS key policies scope by principal/condition; Resource "*" means "this key" and is the required idiom.
  #checkov:skip=CKV_AWS_111:The root kms:* statement is the standard key-admin anchor so the key is never orphaned.
  #checkov:skip=CKV_AWS_109:The service statement is constrained by the SNS topic encryption context.
  statement {
    sid       = "EnableRootPermissions"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.security_account_id}:root"]
    }
  }

  # EventBridge cannot publish to a topic under the AWS-managed aws/sns key, so
  # the topic gets this key and EventBridge gets use of it for this topic only.
  statement {
    sid       = "AllowEventBridgeForFindingsTopic"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = ["arn:aws:sns:${var.region}:${local.security_account_id}:security-findings"]
    }
  }
}

resource "aws_kms_key" "findings" {
  provider = aws.security

  description             = "CMK for the security-findings topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.findings_key.json

  tags = { Name = "security-findings-cmk" }
}

resource "aws_kms_alias" "findings" {
  provider = aws.security

  name          = "alias/security-findings-cmk"
  target_key_id = aws_kms_key.findings.key_id
}

resource "aws_sns_topic" "findings" {
  provider = aws.security

  name              = "security-findings"
  kms_master_key_id = aws_kms_key.findings.arn
}

data "aws_iam_policy_document" "findings_topic" {
  statement {
    sid       = "AllowFindingRulesPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.findings.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.guardduty_high.arn,
        aws_cloudwatch_event_rule.securityhub_high.arn,
      ]
    }
  }
}

resource "aws_sns_topic_policy" "findings" {
  provider = aws.security

  arn    = aws_sns_topic.findings.arn
  policy = data.aws_iam_policy_document.findings_topic.json
}

resource "aws_sns_topic_subscription" "findings_email" {
  count    = var.alert_email == null ? 0 : 1
  provider = aws.security

  topic_arn = aws_sns_topic.findings.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# GuardDuty severity is numeric: 7.0 to 8.9 is HIGH, 9.0 and up is CRITICAL.
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  provider = aws.security

  name        = "guardduty-high-critical"
  description = "GuardDuty findings at HIGH or CRITICAL severity, org-wide"

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
    }
  })
}

# Security Hub re-imports GuardDuty findings, so GuardDuty is excluded here to
# avoid paging twice for one event. Only new, active findings route.
resource "aws_cloudwatch_event_rule" "securityhub_high" {
  provider = aws.security

  name        = "securityhub-high-critical"
  description = "Security Hub findings at HIGH or CRITICAL severity, excluding GuardDuty duplicates"

  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity    = { Label = ["HIGH", "CRITICAL"] }
        Workflow    = { Status = ["NEW"] }
        RecordState = ["ACTIVE"]
        ProductName = [{ "anything-but" = "GuardDuty" }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high" {
  provider = aws.security

  rule      = aws_cloudwatch_event_rule.guardduty_high.name
  target_id = "security-findings"
  arn       = aws_sns_topic.findings.arn
}

resource "aws_cloudwatch_event_target" "securityhub_high" {
  provider = aws.security

  rule      = aws_cloudwatch_event_rule.securityhub_high.name
  target_id = "security-findings"
  arn       = aws_sns_topic.findings.arn
}
