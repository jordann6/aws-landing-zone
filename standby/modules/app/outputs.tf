output "api_endpoint" {
  value = aws_apigatewayv2_api.this.api_endpoint
}

output "api_domain" {
  value = replace(aws_apigatewayv2_api.this.api_endpoint, "https://", "")
}

output "function_name" {
  value = aws_lambda_function.api.function_name
}
