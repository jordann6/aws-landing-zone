# EKS workload metrics via Container Insights (ADR-0002). The managed
# amazon-cloudwatch-observability add-on runs the CloudWatch agent and Fluent Bit
# as DaemonSets. Its service account assumes this role through IRSA, so no node
# credentials are widened. Metrics land in CloudWatch in this account, flow to
# the monitoring account over the OAM link, and drive the central
# eks-failed-nodes alarm (observability/alarms.tf).

data "aws_iam_policy_document" "cloudwatch_agent_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_agent" {
  name               = "prod-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_agent_trust.json
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name             = aws_eks_cluster.prod.name
  addon_name               = "amazon-cloudwatch-observability"
  service_account_role_arn = aws_iam_role.cloudwatch_agent.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The DaemonSets need nodes to schedule on, and the agent needs the logs and
  # monitoring endpoints, since nodes have no internet path except the allowlist.
  depends_on = [
    aws_eks_node_group.prod,
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_vpc_endpoint.interface,
  ]
}
