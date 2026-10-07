output "function_name" {
  value = aws_lambda_function.failover.function_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.failover_events.arn
}

output "alarm_name" {
  value = aws_cloudwatch_metric_alarm.primary_health.alarm_name
}
