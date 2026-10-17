output "checker_function_name" {
  value = aws_lambda_function.checker.function_name
}

output "log_table_name" {
  value = aws_dynamodb_table.logs.name
}

output "alarm_names" {
  value = [
    aws_cloudwatch_metric_alarm.down.alarm_name,
    aws_cloudwatch_metric_alarm.latency.alarm_name,
    aws_cloudwatch_metric_alarm.certificate.alarm_name,
  ]
}
