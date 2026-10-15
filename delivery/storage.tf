# One customer-managed key for the delivery layer's registries and deployment table.
resource "aws_kms_key" "delivery" {
  description             = "release-guard delivery: ECR repositories and deployment table"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.delivery_key.json
}

# Administration stays with the account; use is allowed only through ECR and
# DynamoDB, so a role's key permission cannot be used to decrypt data directly.
data "aws_iam_policy_document" "delivery_key" {
  #checkov:skip=CKV_AWS_109:Key policies apply to this key only; "*" is the key itself.
  #checkov:skip=CKV_AWS_111:Key policies apply to this key only; "*" is the key itself.
  #checkov:skip=CKV_AWS_356:Key policies apply to this key only; "*" is the key itself.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account}:root"]
    }
  }
  statement {
    sid       = "UseThroughEcrAndDynamoDb"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ecr.${var.region}.amazonaws.com", "dynamodb.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_alias" "delivery" {
  name          = "alias/${local.name}-delivery"
  target_key_id = aws_kms_key.delivery.key_id
}

locals {
  # app: application images; deploy: release artifacts (ADR-0003); verifier and
  # the Flux controllers are platform images mirrored by the operator, so the
  # private cluster pulls everything from ECR.
  repositories = {
    app                    = "${local.name}/app"
    deploy                 = "${local.name}/deploy"
    verifier               = "${local.name}/verifier"
    flux-source-controller = "flux/source-controller"
    flux-kustomize         = "flux/kustomize-controller"
  }
}

resource "aws_ecr_repository" "this" {
  for_each             = local.repositories
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo teardown; images are rebuilt from source

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.delivery.arn
  }

  tags = each.key == "deploy" ? { DeliveryGeneration = random_id.generation.hex } : {}
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the most recent 100 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 100
      }
      action = { type = "expire" }
    }]
  })
}

# Deployment records, verdicts and override grants (ADR-0006).
resource "aws_dynamodb_table" "deployments" {
  #checkov:skip=CKV2_AWS_16:On-demand capacity; auto scaling does not apply.
  name         = "${local.name}-deployments"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.delivery.arn
  }

  deletion_protection_enabled = false # deploy, demo, destroy
}
