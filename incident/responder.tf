# Alarm reader in shared-services (the monitoring account). The incident
# responder runs in prod, but the central alarms live here, so its re-check
# ("did the remediation clear the alarm?") assumes this read-only role. It
# trusts exactly the responder's remediation role, inside this organization.

data "aws_iam_policy_document" "alarm_reader_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.prod_account_id}:root"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${local.prod_account_id}:role/${var.responder_role_name}"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [local.acct.organization_id]
    }
  }
}

data "aws_iam_policy_document" "alarm_reader" {
  statement {
    sid       = "ReadCentralAlarms"
    actions   = ["cloudwatch:DescribeAlarms", "cloudwatch:DescribeAlarmHistory"]
    resources = ["arn:aws:cloudwatch:${var.region}:${local.monitoring_account_id}:alarm:*"]
  }
}

resource "aws_iam_role" "alarm_reader" {
  provider = aws.monitoring

  name               = "incident-alarm-reader"
  assume_role_policy = data.aws_iam_policy_document.alarm_reader_trust.json
}

resource "aws_iam_role_policy" "alarm_reader" {
  provider = aws.monitoring

  name   = "read-central-alarms"
  role   = aws_iam_role.alarm_reader.id
  policy = data.aws_iam_policy_document.alarm_reader.json
}

# Private home for the responder's n8n image. Docker Hub is off the firewall
# allowlist, so the image is copied in once, by digest, and the responder pins
# that digest. Standing (a few cents a month for one image) so the copy
# survives the hourly teardowns.
resource "aws_ecr_repository" "n8n" {
  #checkov:skip=CKV_AWS_136:AES-256 at rest; a CMK would outlive the image's value for a public upstream image.
  provider = aws.prod

  name                 = "incident-responder/n8n"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "n8n" {
  provider = aws.prod

  repository = aws_ecr_repository.n8n.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the three newest images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 3
      }
      action = { type = "expire" }
    }]
  })
}
