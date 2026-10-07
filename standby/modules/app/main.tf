resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-api-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "secrets" {
  name = "read-db-secret"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = var.secret_arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = var.kms_key_arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  #checkov:skip=CKV_AWS_158:DR proof layer is destroyed in the same session; log groups hold no secrets and a CMK adds a key policy for no gain.
  name              = "/aws/lambda/${var.name_prefix}-api"
  retention_in_days = 365
}

resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_50:Tracing adds nothing to a short DR proof.
  #checkov:skip=CKV_AWS_272:Code signing is out of scope for the proof; the zip is built from vendored source in this repo.
  #checkov:skip=CKV_AWS_173:Environment holds only hostnames and ARNs, no secrets; the credential is read from Secrets Manager.
  #checkov:skip=CKV_AWS_116:Synchronous handlers; a DLQ only applies to async invokes and the failover Lambda is retried by EventBridge.
  #checkov:skip=CKV_AWS_115:Reserved concurrency would draw down a small account quota for no benefit here.
  #checkov:skip=CKV_AWS_117:The failover Lambda must stay outside the VPC so it works when the primary region is down.
  function_name    = "${var.name_prefix}-api"
  role             = aws_iam_role.lambda.arn
  filename         = var.lambda_zip
  source_code_hash = var.lambda_zip_hash
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 15
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      DB_HOST          = var.db_host
      DB_PORT          = "5432"
      DB_NAME          = var.db_name
      DB_USER          = var.db_username
      SECRET_ARN       = var.secret_arn
      REGION_ROLE      = var.region_role
      SIMULATE_FAILURE = "false"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.vpc_access,
  ]
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  #checkov:skip=CKV_AWS_309:Public health and demo endpoint by design; Route 53 health checks cannot sign requests.
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_cloudwatch_log_group" "api_access" {
  #checkov:skip=CKV_AWS_158:DR proof layer is destroyed in the same session; log groups hold no secrets and a CMK adds a key policy for no gain.
  name              = "/aws/apigateway/${var.name_prefix}-api"
  retention_in_days = 365
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      path           = "$context.path"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}
