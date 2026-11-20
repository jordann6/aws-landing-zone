# Org-wide AWS Config (Step 5). Before this, Config recorded only in the
# security account, so an aggregator would have listed every other account with
# no data, and Firewall Manager (which needs Config wherever it applies) could not
# work. Three pieces:
#
#   1. a standard, narrow recorder in every member account, deployed by a
#      service-managed StackSet that auto-deploys to new accounts in the target OUs
#   2. the same recorder in the management account (StackSets never target it)
#   3. an organization aggregator in the security account, the Config delegated
#      administrator (accounts/delegated-admins.tf)
#
# All of it delivers to the existing org-config bucket in log-archive.
#
# The member recorders are standing. The root deny-disable-detective SCP stops
# anyone but the break-glass role from stopping or deleting them, which is the
# point. Recording is limited to the resource types the zone's controls care
# about, so with the hourly stack down there is almost nothing to record:
# well under $1/month at $0.003 per configuration item.

locals {
  config_recorded_types = [
    "AWS::EC2::SecurityGroup",
    "AWS::EC2::Instance",
    "AWS::ElasticLoadBalancingV2::LoadBalancer",
    "AWS::WAFv2::WebACL",
    "AWS::S3::Bucket",
  ]

  # Every account that delivers Config data to the org bucket.
  config_source_accounts = distinct(concat(
    [local.management_account_id],
    values(local.acct.account_ids),
  ))

  # OUs the member recorder StackSet targets. Security already has its recorder
  # (config.tf); Suspended is frozen by deny-all and must not be targeted.
  config_target_ous = [
    local.acct.infrastructure_ou_id,
    local.acct.sandbox_ou_id,
    local.acct.workloads_ou_id,
    local.acct.deployments_ou_id,
  ]
}

# --- 1. Member recorders (StackSet) --------------------------------------------
resource "aws_cloudformation_stack_set" "config_recorders" {
  name             = "lz-config-recorder"
  description      = "Org-standard AWS Config recorder in every member account (aws-landing-zone Step 5)"
  permission_model = "SERVICE_MANAGED"
  capabilities     = ["CAPABILITY_NAMED_IAM"]

  auto_deployment {
    enabled = true
    # Retain on removal: an account moved to Suspended leaves the target OUs, and
    # the stack's delete would be denied by deny-disable-detective anyway. The
    # deny-all freeze is what stops it from recording.
    retain_stacks_on_account_removal = true
  }

  operation_preferences {
    failure_tolerance_count = 0
    max_concurrent_count    = 4
  }

  parameters = {
    ConfigBucket = aws_s3_bucket.config.id
  }

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Org-standard AWS Config recorder (aws-landing-zone)"
    Parameters = {
      ConfigBucket = { Type = "String" }
    }
    Resources = {
      RecorderRole = {
        Type = "AWS::IAM::Role"
        Properties = {
          RoleName = "lz-config-recorder"
          AssumeRolePolicyDocument = {
            Version = "2012-10-17"
            Statement = [{
              Effect    = "Allow"
              Principal = { Service = "config.amazonaws.com" }
              Action    = "sts:AssumeRole"
            }]
          }
          ManagedPolicyArns = ["arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"]
          Policies = [{
            PolicyName = "config-s3-delivery"
            PolicyDocument = {
              Version = "2012-10-17"
              Statement = [
                {
                  Effect    = "Allow"
                  Action    = "s3:PutObject"
                  Resource  = { "Fn::Sub" = "arn:aws:s3:::$${ConfigBucket}/AWSLogs/$${AWS::AccountId}/Config/*" }
                  Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
                },
                {
                  Effect   = "Allow"
                  Action   = "s3:GetBucketAcl"
                  Resource = { "Fn::Sub" = "arn:aws:s3:::$${ConfigBucket}" }
                },
              ]
            }
          }]
        }
      }
      Recorder = {
        Type = "AWS::Config::ConfigurationRecorder"
        Properties = {
          Name    = "lz-config-recorder"
          RoleARN = { "Fn::GetAtt" = ["RecorderRole", "Arn"] }
          RecordingGroup = {
            AllSupported               = false
            IncludeGlobalResourceTypes = false
            ResourceTypes              = local.config_recorded_types
            RecordingStrategy          = { UseOnly = "INCLUSION_BY_RESOURCE_TYPES" }
          }
        }
      }
      # CloudFormation starts the recorder once its delivery channel exists.
      DeliveryChannel = {
        Type = "AWS::Config::DeliveryChannel"
        Properties = {
          Name         = "lz-config-delivery"
          S3BucketName = { Ref = "ConfigBucket" }
        }
      }
    }
  })

  lifecycle {
    ignore_changes = [administration_role_arn]
  }

  depends_on = [aws_s3_bucket_policy.config]
}

resource "aws_cloudformation_stack_set_instance" "config_recorders" {
  stack_set_name = aws_cloudformation_stack_set.config_recorders.name
  region         = var.region

  deployment_targets {
    organizational_unit_ids = local.config_target_ous
  }

  # Retain, for the same reason as auto_deployment above.
  retain_stack = true
}

# --- 2. Management account recorder ---------------------------------------------
# StackSets never deploy to the management account. No SCP binds it, so this
# recorder is the one Config recorder in the org that Terraform can also remove.
resource "aws_iam_role" "config_management" {
  name               = "lz-config-recorder"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config_management" {
  role       = aws_iam_role.config_management.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_management_delivery" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${local.management_account_id}/Config/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
  statement {
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
  }
}

resource "aws_iam_role_policy" "config_management" {
  name   = "config-s3-delivery"
  role   = aws_iam_role.config_management.id
  policy = data.aws_iam_policy_document.config_management_delivery.json
}

resource "aws_config_configuration_recorder" "management" {
  #checkov:skip=CKV2_AWS_48:Deliberately narrow (config_recorded_types) to keep standing Config cost near zero; the security account records all supported types.
  name     = "lz-config-recorder"
  role_arn = aws_iam_role.config_management.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types                = local.config_recorded_types
    recording_strategy {
      use_only = "INCLUSION_BY_RESOURCE_TYPES"
    }
  }
}

resource "aws_config_delivery_channel" "management" {
  name           = "lz-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  depends_on = [
    aws_config_configuration_recorder.management,
    aws_s3_bucket_policy.config,
  ]
}

resource "aws_config_configuration_recorder_status" "management" {
  #checkov:skip=CKV2_AWS_45:Recorder is deliberately narrow (see the recorder above); it is enabled.
  name       = aws_config_configuration_recorder.management.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.management]
}

# --- 3. Organization aggregator (security account) ------------------------------
data "aws_iam_policy_document" "config_aggregator_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config_aggregator" {
  provider           = aws.security
  name               = "config-org-aggregator"
  assume_role_policy = data.aws_iam_policy_document.config_aggregator_assume.json
}

resource "aws_iam_role_policy_attachment" "config_aggregator" {
  provider   = aws.security
  role       = aws_iam_role.config_aggregator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

resource "aws_config_configuration_aggregator" "org" {
  provider = aws.security
  name     = "org-aggregator"

  # All regions costs nothing here: region-lockdown keeps every member in
  # us-east-1, so the other regions report empty, and a recorder that ever
  # appears elsewhere shows up instead of hiding.
  organization_aggregation_source {
    all_regions = true
    role_arn    = aws_iam_role.config_aggregator.arn
  }

  depends_on = [aws_iam_role_policy_attachment.config_aggregator]
}

output "config_aggregator_arn" {
  value = aws_config_configuration_aggregator.org.arn
}
