# Private registry as the only image source. Public registries are denied two
# ways: the hub firewall's domain allowlist does not include Docker Hub, and the
# private VPC has no internet path, so a node literally cannot reach one. Images
# arrive only through ECR, and public images only through the pull-through cache,
# which mirrors them into ECR where they get scanned.

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "app" {
  name                 = "app"
  image_tag_mutability = "IMMUTABLE" # a tag cannot be moved to a different image

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.data.arn
  }

  tags = { Name = "app" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

# Pull-through cache for public.ecr.aws. A pull of ecr-public/... is mirrored into
# this account's ECR, so even upstream images land somewhere scannable. Docker Hub
# and quay need a credential secret and are left as a documented addition.
resource "aws_ecr_pull_through_cache_rule" "public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

# Inspector enhanced scanning: continuous CVE scanning of ECR images and EC2.
resource "aws_inspector2_enabler" "this" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]
}

resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.this]
}
