# CloudWatch cross-account observability. Shared-services is the monitoring
# account: it holds the sink, and prod and network link to it, sharing metrics,
# logs, and traces. Alarms and dashboards then live in one account that no
# workload team can change, while the data stays in the account that produced it.

locals {
  oam_resource_types = [
    "AWS::CloudWatch::Metric",
    "AWS::Logs::LogGroup",
    "AWS::XRay::Trace",
  ]

  oam_source_accounts = [local.prod_account_id, local.network_account_id]
}

resource "aws_oam_sink" "monitoring" {
  provider = aws.monitoring

  name = "org-monitoring"
}

# Only the named source accounts may link, and only for these resource types.
data "aws_iam_policy_document" "sink" {
  statement {
    actions   = ["oam:CreateLink", "oam:UpdateLink"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = local.oam_source_accounts
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "oam:ResourceTypes"
      values   = local.oam_resource_types
    }
  }
}

resource "aws_oam_sink_policy" "monitoring" {
  provider = aws.monitoring

  sink_identifier = aws_oam_sink.monitoring.arn
  policy          = data.aws_iam_policy_document.sink.json
}

resource "aws_oam_link" "prod" {
  provider = aws.prod

  label_template  = "$AccountName"
  resource_types  = local.oam_resource_types
  sink_identifier = aws_oam_sink.monitoring.arn

  depends_on = [aws_oam_sink_policy.monitoring]
}

resource "aws_oam_link" "network" {
  provider = aws.network

  label_template  = "$AccountName"
  resource_types  = local.oam_resource_types
  sink_identifier = aws_oam_sink.monitoring.arn

  depends_on = [aws_oam_sink_policy.monitoring]
}

# A new link takes a few minutes before the monitoring account may query the
# source account's metrics; until then GetMetricData and PutMetricAlarm return
# "Forbidden" (measured at about 3.7 minutes on 2026-10-04). Alarms wait on this.
resource "time_sleep" "oam_propagation" {
  create_duration = "5m"

  depends_on = [aws_oam_link.prod, aws_oam_link.network]
}
