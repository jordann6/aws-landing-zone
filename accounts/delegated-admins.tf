# Security is the delegated administrator for AWS Config, so the org-wide
# configuration aggregator (terraform/config-aggregator.tf) lives in the security
# account beside GuardDuty and Security Hub, not in the management account.
resource "aws_organizations_delegated_administrator" "config" {
  account_id        = aws_organizations_account.this["security"].id
  service_principal = "config.amazonaws.com"
}
