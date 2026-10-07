terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "scanner_role_arn" {
  description = "Exact scanner role allowed to assume this target"
  type        = string
}

variable "scanner_account_id" {
  description = "Scanner home account"
  type        = string
}

variable "organization_id" {
  description = "Organization the scanner must belong to"
  type        = string
}

variable "role_name" {
  description = "Scan-target role name, matched by the scanner's AssumeRole allow list"
  type        = string
}

data "aws_caller_identity" "target" {}

resource "aws_iam_role" "target" {
  name = var.role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.scanner_account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        ArnEquals    = { "aws:PrincipalArn" = var.scanner_role_arn }
        StringEquals = { "aws:PrincipalOrgID" = var.organization_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "metadata" {
  name = "secrets-metadata-only"
  role = aws_iam_role.target.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListInventoryMetadata"
        Effect = "Allow"
        Action = [
          "secretsmanager:ListSecrets", "ssm:DescribeParameters",
          "iam:ListUsers"
        ]
        Resource = "*"
      },
      {
        Sid      = "ReadSecretMetadata"
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "secretsmanager:ListSecretVersionIds"]
        Resource = "arn:aws:secretsmanager:*:${data.aws_caller_identity.target.account_id}:secret:*"
      },
      {
        Sid      = "ReadParameterTags"
        Effect   = "Allow"
        Action   = "ssm:ListTagsForResource"
        Resource = "arn:aws:ssm:*:${data.aws_caller_identity.target.account_id}:parameter/*"
      },
      {
        Sid      = "ReadUserKeyMetadata"
        Effect   = "Allow"
        Action   = ["iam:ListAccessKeys", "iam:GetAccessKeyLastUsed"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.target.account_id}:user/*"
      },
      {
        Sid    = "DenySecretMaterial"
        Effect = "Deny"
        Action = [
          "secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue",
          "ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })
}

output "role_arn" {
  description = "Scan-target role ARN"
  value       = aws_iam_role.target.arn
}
