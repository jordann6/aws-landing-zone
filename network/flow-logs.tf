# VPC flow logs for the hub, so there is a record of what traversed the
# inspection VPC independent of the firewall's own logs.

resource "aws_cloudwatch_log_group" "vpc_flow" {
  #checkov:skip=CKV_AWS_338:14-day retention for a demo; a year is a production setting.
  #checkov:skip=CKV_AWS_158:CloudWatch CMK encryption is the production upgrade; demo uses the default key.
  name              = "/vpc/hub-flow"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  name               = "hub-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
}

# No logs:CreateLogGroup. Terraform owns the group. With that permission, flow
# log delivery still in flight during a destroy re-created /vpc/hub-flow right
# after Terraform deleted it (2026-10-15 16:58 UTC, no retention, empty), and the
# next apply failed with ResourceAlreadyExistsException. Matches workload.
data "aws_iam_policy_document" "flow_write" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  name   = "flow-logs-write"
  role   = aws_iam_role.flow.id
  policy = data.aws_iam_policy_document.flow_write.json
}

resource "aws_flow_log" "hub" {
  vpc_id          = aws_vpc.hub.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.vpc_flow.arn
  iam_role_arn    = aws_iam_role.flow.arn
}
