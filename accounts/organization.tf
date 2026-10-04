resource "aws_organizations_organization" "org" {
  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "config-multiaccountsetup.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "access-analyzer.amazonaws.com",
    "ram.amazonaws.com",
    "sso.amazonaws.com",
  ]

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
    "TAG_POLICY",
  ]

  feature_set = "ALL"

  # The org outlives every teardown; see accounts.tf.
  lifecycle {
    prevent_destroy = true
  }
}
