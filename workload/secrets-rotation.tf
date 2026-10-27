# Secret rotation for the one database client that cannot use IAM auth.
#
# The orders app reads no secrets: orders-api and orders-migrator log in with
# short-lived IAM tokens (release-guard ADR-0004). orders_reporting stands in for a
# BI tool or third party that only speaks passwords, so it gets the other half of
# the policy: a Secrets Manager credential rotated with the alternating-users
# scheme. The rotation function clones orders_reporting to orders_reporting_clone
# and swaps between them, so the previous credential stays valid while the next
# one is set. "IAM tokens where the client supports them; alternating-user
# rotation where it can't."
#
# No password lives in Terraform. The secret is created empty; the operator script
# scripts/rotation-bootstrap.sh creates the DB user, seeds the secret and only then
# turns rotation on. Enabling rotation here, before the user exists, would run the
# function's testSecret against a missing user and can strand AWSPENDING on an
# empty version, blocking every later rotation.
#
# Both functions run in the app subnets (the data NACL admits the app tier on
# 5432) with no internet path: Secrets Manager and RDS through interface
# endpoints, PostgreSQL directly.

locals {
  rotation_name   = "prod-orders-reporting"
  app_subnet_ids  = [for k, s in local.subnets : aws_subnet.this[k].id if s.tier == "app"]
  data_cidrs      = [for k, s in local.subnets : s.cidr if s.tier == "data"]
  rotation_lambda = "${local.rotation_name}-rotation"
  load_lambda     = "${local.rotation_name}-load"
}

resource "aws_secretsmanager_secret" "reporting" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV2_AWS_57:Rotation is enabled by scripts/rotation-bootstrap.sh once the DB user exists and the secret holds a value; see the header.
  name        = "prod/orders-reporting"
  description = "orders_reporting PostgreSQL credential (password-auth client), rotated with alternating users"
  kms_key_id  = aws_kms_key.data[0].arn

  # Deploy/demo/destroy posture: a recovery window would hold the name and fail
  # the next deploy's create.
  recovery_window_in_days = 0

  tags = { Name = "prod-orders-reporting" }
}

# ---- network -----------------------------------------------------------------

resource "aws_security_group" "rotation" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV2_AWS_5:Attached by both functions' vpc_config below; checkov does not follow the count index.
  name        = "prod-db-password-clients"
  description = "Rotation function and reporting load client: PostgreSQL and the API endpoints only"
  vpc_id      = aws_vpc.prod.id

  egress {
    description = "PostgreSQL to the data subnets"
    from_port   = local.db_port
    to_port     = local.db_port
    protocol    = "tcp"
    cidr_blocks = local.data_cidrs
  }

  egress {
    description     = "HTTPS to the interface endpoints (Secrets Manager, RDS)"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.endpoints.id]
  }

  tags = { Name = "prod-db-password-clients" }
}

# The template reads the master secret, which RDS manages and which holds only a
# username and password; it resolves the host through DescribeDBInstances.
resource "aws_vpc_endpoint" "rds" {
  count = var.enable_rds ? 1 : 0

  vpc_id              = aws_vpc.prod.id
  service_name        = "com.amazonaws.${var.region}.rds"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.node_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "prod-rds" }
}

# ---- package -----------------------------------------------------------------

# build/rotation is staged by rotation/build.sh (CI: platform-guardrails
# build_command), and the zip travels with the saved plan to the apply job.
data "archive_file" "rotation" {
  count            = var.enable_rds ? 1 : 0
  type             = "zip"
  source_dir       = "${path.module}/build/rotation"
  output_path      = "${path.module}/build/rotation.zip"
  output_file_mode = "0644"
}

# ---- rotation function -----------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_group" "rotation" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV_AWS_158:The data CMK's default key policy does not admit CloudWatch Logs; the logs hold step names and usernames, never secret values.
  #checkov:skip=CKV_AWS_338:30-day retention for an operational log in a deploy/demo/destroy stack.
  name              = "/aws/lambda/${local.rotation_lambda}"
  retention_in_days = 30
}

data "aws_iam_policy_document" "rotation" {
  count = var.enable_rds ? 1 : 0

  statement {
    sid = "RotateTheReportingSecret"
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.reporting[0].arn]
  }

  # Master credential: read only, to create the clone user and set passwords.
  # DescribeSecret reads its aws:rds system tag, which names the instance.
  statement {
    sid       = "ReadTheMasterSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_db_instance.prod[0].master_user_secret[0].secret_arn]
  }

  statement {
    #checkov:skip=CKV_AWS_356:GetRandomPassword does not support resource-level permissions.
    sid       = "GeneratePasswords"
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  statement {
    sid       = "ResolveTheMasterHost"
    actions   = ["rds:DescribeDBInstances"]
    resources = [aws_db_instance.prod[0].arn]
  }

  statement {
    sid       = "UseTheDataKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.data[0].arn]
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.rotation[0].arn}:*"]
  }

  statement {
    #checkov:skip=CKV_AWS_111:Lambda's VPC ENI actions do not support resource-level scoping on create.
    #checkov:skip=CKV_AWS_356:Same: the ENI actions need "*".
    sid = "AttachToTheVpc"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "rotation" {
  count              = var.enable_rds ? 1 : 0
  name               = local.rotation_lambda
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "rotation" {
  count  = var.enable_rds ? 1 : 0
  name   = "rotate-orders-reporting"
  role   = aws_iam_role.rotation[0].id
  policy = data.aws_iam_policy_document.rotation[0].json
}

resource "aws_lambda_function" "rotation" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV_AWS_115:The account Lambda concurrency quota is 10; a reservation would drop unreserved concurrency below the minimum. Secrets Manager serializes rotations per secret.
  #checkov:skip=CKV_AWS_116:Secrets Manager is the caller and records each failed step; a DLQ would hold nothing it does not.
  #checkov:skip=CKV_AWS_272:Code signing adds a signing pipeline for one function in a sandbox-scale account; the package is hash-pinned and rebuilt reproducibly.
  #checkov:skip=CKV_AWS_173:The environment holds an endpoint URL, no secrets.
  #checkov:skip=CKV_AWS_50:The private VPC has no X-Ray endpoint; the four rotation steps are logged to CloudWatch.
  function_name    = local.rotation_lambda
  description      = "Alternating-users rotation for the orders_reporting secret (AWS sample, psycopg2 port)"
  role             = aws_iam_role.rotation[0].arn
  runtime          = "python3.13"
  architectures    = ["x86_64"]
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.rotation[0].output_path
  source_code_hash = data.archive_file.rotation[0].output_base64sha256
  timeout          = 60
  memory_size      = 256

  vpc_config {
    subnet_ids         = local.app_subnet_ids
    security_group_ids = [aws_security_group.rotation[0].id]
  }

  environment {
    variables = {
      SECRETS_MANAGER_ENDPOINT = "https://secretsmanager.${var.region}.amazonaws.com"
    }
  }

  depends_on = [aws_cloudwatch_log_group.rotation, aws_iam_role_policy.rotation]
}

resource "aws_lambda_permission" "rotation" {
  count          = var.enable_rds ? 1 : 0
  statement_id   = "AllowSecretsManager"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.rotation[0].function_name
  principal      = "secretsmanager.amazonaws.com"
  source_arn     = aws_secretsmanager_secret.reporting[0].arn
  source_account = data.aws_caller_identity.prod.account_id
}

# ---- reporting load client (the proof's receipt) ------------------------------

resource "aws_cloudwatch_log_group" "load" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV_AWS_158:The data CMK's default key policy does not admit CloudWatch Logs; the logs hold usernames and version ids, never secret values.
  #checkov:skip=CKV_AWS_338:30-day retention for an operational log in a deploy/demo/destroy stack.
  name              = "/aws/lambda/${local.load_lambda}"
  retention_in_days = 30
}

# Reads exactly one secret. No master access, no write, no other credential.
data "aws_iam_policy_document" "load" {
  count = var.enable_rds ? 1 : 0

  statement {
    sid       = "ReadTheReportingSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.reporting[0].arn]
  }

  statement {
    sid       = "DecryptThroughSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data[0].arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.load[0].arn}:*"]
  }

  statement {
    #checkov:skip=CKV_AWS_111:Lambda's VPC ENI actions do not support resource-level scoping on create.
    #checkov:skip=CKV_AWS_356:Same: the ENI actions need "*".
    sid = "AttachToTheVpc"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "load" {
  count              = var.enable_rds ? 1 : 0
  name               = local.load_lambda
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "load" {
  count  = var.enable_rds ? 1 : 0
  name   = "read-orders-reporting"
  role   = aws_iam_role.load[0].id
  policy = data.aws_iam_policy_document.load[0].json
}

resource "aws_lambda_function" "load" {
  count = var.enable_rds ? 1 : 0
  #checkov:skip=CKV_AWS_115:The account Lambda concurrency quota is 10; a reservation would drop unreserved concurrency below the minimum. The proof invokes it once.
  #checkov:skip=CKV_AWS_116:Invoked by the operator for a proof; a failed run is read from its own summary.
  #checkov:skip=CKV_AWS_272:Code signing adds a signing pipeline for one function in a sandbox-scale account; the package is hash-pinned and rebuilt reproducibly.
  #checkov:skip=CKV_AWS_173:The environment holds a secret ARN, no secret value.
  #checkov:skip=CKV_AWS_50:The private VPC has no X-Ray endpoint; every query is logged to CloudWatch.
  function_name    = local.load_lambda
  description      = "Reporting client stand-in: queries as orders_reporting while rotations run"
  role             = aws_iam_role.load[0].arn
  runtime          = "python3.13"
  architectures    = ["x86_64"]
  handler          = "reporting_load.lambda_handler"
  filename         = data.archive_file.rotation[0].output_path
  source_code_hash = data.archive_file.rotation[0].output_base64sha256
  timeout          = 900
  memory_size      = 256

  vpc_config {
    subnet_ids         = local.app_subnet_ids
    security_group_ids = [aws_security_group.rotation[0].id]
  }

  environment {
    variables = {
      SECRET_ARN = aws_secretsmanager_secret.reporting[0].arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.load, aws_iam_role_policy.load]
}
