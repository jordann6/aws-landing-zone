# Management-account root hardening. The parts Terraform can enforce: a strong
# password policy, and an alarm on any root use so the account nobody should log
# in with cannot be used quietly. The parts it cannot (enable a hardware MFA on
# root, delete root access keys) are one-time console actions documented in
# docs/access-model.md; the alarm below is what proves they stay done.

resource "aws_iam_account_password_policy" "strict" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  password_reuse_prevention      = 24
  max_password_age               = 90
  hard_expiry                    = false
}

#trivy:ignore:AVD-AWS-0136:AWS-managed SNS key in the demo; a CMK for the alert topic is the production upgrade.
resource "aws_sns_topic" "security_alerts" {
  name              = "security-alerts"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.budget_notification_email
}

data "aws_iam_policy_document" "security_alerts_topic" {
  statement {
    sid       = "AllowEventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts_topic.json
}

# Any sign-in or API call made as the account root fires this.
resource "aws_cloudwatch_event_rule" "root_activity" {
  name        = "root-account-activity"
  description = "Alert on any use of the account root user"

  event_pattern = jsonencode({
    "detail-type" = [
      "AWS Console Sign In via CloudTrail",
      "AWS API Call via CloudTrail"
    ]
    "detail" = {
      "userIdentity" = {
        "type" = ["Root"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "root_activity_sns" {
  rule      = aws_cloudwatch_event_rule.root_activity.name
  target_id = "security-alerts"
  arn       = aws_sns_topic.security_alerts.arn
}
