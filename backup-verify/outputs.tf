output "bucket_name" {
  value = aws_s3_bucket.backups.bucket
}

output "checker_function_name" {
  value = aws_lambda_function.checker.function_name
}

output "alarm_name" {
  value = try(aws_cloudwatch_metric_alarm.stale[0].alarm_name, null)
}
