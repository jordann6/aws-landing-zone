# Member accounts are permanent. They live in this root, which is never part of
# a teardown, so a destroy of the billable layers leaves every account ACTIVE.
#
# close_on_deletion = false: closing an account leaves it SUSPENDED for 90 days,
# still counted against the org account quota and still holding its email alias,
# so a redeploy collides with it. Idle accounts cost nothing.
# prevent_destroy: with close_on_deletion off, a destroy would try to remove the
# account from the org instead, which fails without standalone billing. Refusing
# the plan up front is the honest behavior.

resource "aws_organizations_account" "sandbox" {
  name      = "sandbox"
  email     = replace(var.org_email_domain, "@", "+sandbox@")
  parent_id = aws_organizations_organizational_unit.sandbox.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

# dev/test/prod/network/shared-services are gated by full_account_set. In a fresh
# org with account headroom they all create (the canonical design). Where the org
# is at its account-count limit, set full_account_set=false to deploy the
# governance core plus the security, log-archive, and sandbox accounts only.
resource "aws_organizations_account" "dev" {
  count     = var.full_account_set ? 1 : 0
  name      = "dev"
  email     = replace(var.org_email_domain, "@", "+dev@")
  parent_id = aws_organizations_organizational_unit.dev.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

resource "aws_organizations_account" "test" {
  count     = var.full_account_set ? 1 : 0
  name      = "test"
  email     = replace(var.org_email_domain, "@", "+test@")
  parent_id = aws_organizations_organizational_unit.test.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

resource "aws_organizations_account" "prod" {
  count     = var.full_account_set ? 1 : 0
  name      = "prod"
  email     = replace(var.org_email_domain, "@", "+prod@")
  parent_id = aws_organizations_organizational_unit.prod.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

# --- Security OU ---
# Delegated administrator for the org's detective services (Security Hub,
# GuardDuty, Config aggregator, IAM Access Analyzer). Kept separate from the
# management account so security operations never need management-account access.
resource "aws_organizations_account" "security" {
  name      = "security"
  email     = replace(var.org_email_domain, "@", "+security@")
  parent_id = aws_organizations_organizational_unit.security.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

# --- Infrastructure OU ---
# network: Transit Gateway, egress/inspection VPC, Network Firewall, endpoints.
resource "aws_organizations_account" "network" {
  count     = var.full_account_set ? 1 : 0
  name      = "network"
  email     = replace(var.org_email_domain, "@", "+network@")
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

# shared-services: private DNS resolver, future golden-image pipeline, tooling.
resource "aws_organizations_account" "shared_services" {
  count     = var.full_account_set ? 1 : 0
  name      = "shared-services"
  email     = replace(var.org_email_domain, "@", "+shared-services@")
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}

# log-archive: org CloudTrail (Object-Lock S3) and AWS Config delivery. Write-only
# from the rest of the org; the immutable record of what happened.
resource "aws_organizations_account" "log_archive" {
  name      = "log-archive"
  email     = replace(var.org_email_domain, "@", "+log-archive@")
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}
