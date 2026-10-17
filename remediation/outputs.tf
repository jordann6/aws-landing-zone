output "function_name" {
  value = aws_lambda_function.remediation.function_name
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}

output "oncall_topic_arn" {
  value = aws_sns_topic.oncall.arn
}

output "alarm_names" {
  value = sort([for a in aws_cloudwatch_metric_alarm.high_cpu : a.alarm_name])
}

output "dry_run" {
  value = var.dry_run
}
