output "security_findings_topic_arn" {
  description = "HIGH/CRITICAL GuardDuty + Security Hub findings; the forensics runbook subscribes."
  value       = aws_sns_topic.findings.arn
}

output "ops_topic_arn" {
  description = "Central alarm notifications; the incident responder queue subscribes."
  value       = aws_sns_topic.ops.arn
}

output "monitoring_account_id" {
  value = local.monitoring_account_id
}

output "oam_sink_arn" {
  value = aws_oam_sink.monitoring.arn
}

output "alarm_names" {
  value = sort(keys(aws_cloudwatch_metric_alarm.central))
}

output "ops_topic_kms_key_arn" {
  description = "CMK on the ops topic; the incident responder's remediation role publishes through it"
  value       = aws_kms_key.ops.arn
}
