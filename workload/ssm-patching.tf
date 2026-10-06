# Compute baseline, patching. Systems Manager is the AWS counterpart of Azure
# Update Manager and GCP OS Config:
#   - Default Host Management Configuration makes every IMDSv2 instance in the
#     account SSM-managed without a per-instance policy.
#   - A patch baseline for AL2023 and the "prod" patch group.
#   - A daily compliance scan (runs at creation, so a fresh instance reports
#     straight away) and a weekly install window.
# Instances opt in with the tag `Patch Group = prod`.

data "aws_iam_policy_document" "ssm_default_host_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_default_host" {
  name               = "prod-ssm-default-host-management"
  assume_role_policy = data.aws_iam_policy_document.ssm_default_host_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_default_host" {
  role       = aws_iam_role.ssm_default_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
}

resource "aws_ssm_service_setting" "default_host_management" {
  setting_id    = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.prod.account_id}:servicesetting/ssm/managed-instance/default-ec2-instance-management-role"
  setting_value = aws_iam_role.ssm_default_host.name
  depends_on    = [aws_iam_role_policy_attachment.ssm_default_host]
}

resource "aws_ssm_patch_baseline" "al2023" {
  name             = "prod-al2023"
  description      = "AL2023: security and bugfix updates; critical and important approved immediately"
  operating_system = "AMAZON_LINUX_2023"

  approval_rule {
    approve_after_days  = 0
    compliance_level    = "CRITICAL"
    enable_non_security = false
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security"]
    }
    patch_filter {
      key    = "SEVERITY"
      values = ["Critical", "Important"]
    }
  }

  approval_rule {
    approve_after_days  = 7
    compliance_level    = "MEDIUM"
    enable_non_security = false
    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security", "Bugfix"]
    }
    patch_filter {
      key    = "SEVERITY"
      values = ["Medium", "Low"]
    }
  }
}

resource "aws_ssm_patch_group" "prod" {
  baseline_id = aws_ssm_patch_baseline.al2023.id
  patch_group = "prod"
}

resource "aws_ssm_association" "patch_scan" {
  name                = "AWS-RunPatchBaseline"
  association_name    = "prod-patch-scan"
  schedule_expression = "rate(1 day)"
  compliance_severity = "HIGH"
  max_concurrency     = "100%"
  max_errors          = "100%"

  parameters = {
    Operation = "Scan"
  }

  targets {
    key    = "tag:Patch Group"
    values = ["prod"]
  }
}

resource "aws_ssm_association" "patch_install" {
  name                        = "AWS-RunPatchBaseline"
  association_name            = "prod-patch-install"
  schedule_expression         = "cron(0 6 ? * SUN *)"
  apply_only_at_cron_interval = true
  compliance_severity         = "CRITICAL"
  max_concurrency             = "50%"
  max_errors                  = "0"

  parameters = {
    Operation    = "Install"
    RebootOption = "RebootIfNeeded"
  }

  targets {
    key    = "tag:Patch Group"
    values = ["prod"]
  }
}
