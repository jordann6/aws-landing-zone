# Detective controls, administered from the security account, not the management
# account. Delegating admin keeps day-to-day security operations out of the
# account that can change the org itself.

# --- GuardDuty --------------------------------------------------------------
resource "aws_guardduty_organization_admin_account" "this" {
  admin_account_id = aws_organizations_account.security.id
  depends_on       = [aws_organizations_organization.org]
}

resource "aws_guardduty_detector" "security" {
  provider = aws.security
  enable   = true
}

# Every current and future member account is enrolled automatically.
resource "aws_guardduty_organization_configuration" "this" {
  provider    = aws.security
  detector_id = aws_guardduty_detector.security.id

  auto_enable_organization_members = "ALL"

  depends_on = [aws_guardduty_organization_admin_account.this]
}

# --- Security Hub with the CIS AWS Foundations Benchmark ---------------------
# Gated by enable_securityhub: set false where Security Hub is already enabled in
# the security account (e.g. a shared account) and managed outside this root.
resource "aws_securityhub_organization_admin_account" "this" {
  count            = var.enable_securityhub ? 1 : 0
  admin_account_id = aws_organizations_account.security.id
  depends_on       = [aws_organizations_organization.org]
}

resource "aws_securityhub_account" "security" {
  count    = var.enable_securityhub ? 1 : 0
  provider = aws.security
}

# The scored CIS standard: this is the compliance target the whole zone is graded
# against. Config must be recording for its checks to evaluate (see config.tf).
resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_securityhub ? 1 : 0
  provider      = aws.security
  standards_arn = "arn:aws:securityhub:${var.region}::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.security]
}

resource "aws_securityhub_organization_configuration" "this" {
  count       = var.enable_securityhub ? 1 : 0
  provider    = aws.security
  auto_enable = true
  depends_on = [
    aws_securityhub_organization_admin_account.this,
    aws_securityhub_account.security,
  ]
}
