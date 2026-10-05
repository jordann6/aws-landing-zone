# Central alarms, all in the monitoring account, each reading a metric that lives
# in a source account through the OAM link (metric_query.account_id). They notify
# the ops topic on ALARM and on OK, so the incident responder (Phase D) can both
# act and confirm recovery.
#
# The RDS replica-lag alarm arrives with the cross-region replica in Phase E;
# a Multi-AZ instance does not publish ReplicaLag.

data "aws_iam_policy_document" "ops_key" {
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
      identifiers = ["arn:aws:iam::${local.monitoring_account_id}:root"]
    }
  }

  # CloudWatch alarms, like EventBridge, need a customer-managed key on an
  # encrypted topic.
  statement {
    sid       = "AllowCloudWatchForOpsTopic"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:sns:topicArn"
      values   = ["arn:aws:sns:${var.region}:${local.monitoring_account_id}:ops-alarms"]
    }
  }
}

resource "aws_kms_key" "ops" {
  provider = aws.monitoring

  description             = "CMK for the ops-alarms topic"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.ops_key.json

  tags = { Name = "ops-alarms-cmk" }
}

resource "aws_kms_alias" "ops" {
  provider = aws.monitoring

  name          = "alias/ops-alarms-cmk"
  target_key_id = aws_kms_key.ops.key_id
}

# Default topic policy: same-account CloudWatch alarms may publish.
resource "aws_sns_topic" "ops" {
  provider = aws.monitoring

  name              = "ops-alarms"
  kms_master_key_id = aws_kms_key.ops.arn
}

resource "aws_sns_topic_subscription" "ops_email" {
  count    = var.alert_email == null ? 0 : 1
  provider = aws.monitoring

  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  # One entry per alarm. treat_missing_data is notBreaching everywhere: the
  # hourly layers are down between demos, and an absent metric is not an outage.
  alarms = {
    rds-cpu-high = {
      description = "Prod RDS CPU above ${var.rds_cpu_threshold}% for 15 minutes"
      account_id  = local.prod_account_id
      namespace   = "AWS/RDS"
      metric      = "CPUUtilization"
      dimensions  = { DBInstanceIdentifier = var.rds_instance_id }
      stat        = "Average"
      operator    = "GreaterThanThreshold"
      threshold   = var.rds_cpu_threshold
      periods     = 3
    }
    rds-free-storage-low = {
      description = "Prod RDS free storage below ${var.rds_free_storage_threshold_gb} GB"
      account_id  = local.prod_account_id
      namespace   = "AWS/RDS"
      metric      = "FreeStorageSpace"
      dimensions  = { DBInstanceIdentifier = var.rds_instance_id }
      stat        = "Minimum"
      operator    = "LessThanThreshold"
      threshold   = var.rds_free_storage_threshold_gb * 1024 * 1024 * 1024
      periods     = 1
    }
    # Published by Container Insights (amazon-cloudwatch-observability add-on).
    eks-failed-nodes = {
      description = "Prod EKS has at least one failed node"
      account_id  = local.prod_account_id
      namespace   = "ContainerInsights"
      metric      = "cluster_failed_node_count"
      dimensions  = { ClusterName = var.eks_cluster_name }
      stat        = "Maximum"
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 1
      periods     = 1
    }
    # Stateful drops are the egress allowlist denying a domain.
    firewall-dropped-packets = {
      description = "Network Firewall dropped more than ${var.firewall_dropped_packets_threshold} packets in 5 minutes"
      account_id  = local.network_account_id
      namespace   = "AWS/NetworkFirewall"
      metric      = "DroppedPackets"
      dimensions = {
        FirewallName     = var.firewall_name
        AvailabilityZone = var.firewall_az
        Engine           = "Stateful"
      }
      stat      = "Sum"
      operator  = "GreaterThanThreshold"
      threshold = var.firewall_dropped_packets_threshold
      periods   = 1
    }
    backup-job-failed = {
      description = "An AWS Backup job for the prod vault failed"
      account_id  = local.prod_account_id
      namespace   = "AWS/Backup"
      metric      = "NumberOfBackupJobsFailed"
      dimensions  = { BackupVaultName = var.backup_vault_name }
      stat        = "Sum"
      operator    = "GreaterThanOrEqualToThreshold"
      threshold   = 1
      periods     = 1
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "central" {
  for_each = local.alarms
  provider = aws.monitoring

  alarm_name          = each.key
  alarm_description   = each.value.description
  comparison_operator = each.value.operator
  threshold           = each.value.threshold
  evaluation_periods  = each.value.periods
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops.arn]
  ok_actions    = [aws_sns_topic.ops.arn]

  metric_query {
    id          = "m1"
    return_data = true
    account_id  = each.value.account_id

    metric {
      namespace   = each.value.namespace
      metric_name = each.value.metric
      dimensions  = each.value.dimensions
      stat        = each.value.stat
      period      = 300
    }
  }

  # A source account's metrics are queryable only once its link has propagated.
  depends_on = [time_sleep.oam_propagation]
}
