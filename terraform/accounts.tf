resource "aws_organizations_account" "sandbox" {
  name      = "sandbox"
  email     = replace(var.org_email_domain, "@", "+sandbox@")
  parent_id = aws_organizations_organizational_unit.sandbox.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "dev" {
  name      = "dev"
  email     = replace(var.org_email_domain, "@", "+dev@")
  parent_id = aws_organizations_organizational_unit.dev.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "test" {
  name      = "test"
  email     = replace(var.org_email_domain, "@", "+test@")
  parent_id = aws_organizations_organizational_unit.test.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}

resource "aws_organizations_account" "prod" {
  name      = "prod"
  email     = replace(var.org_email_domain, "@", "+prod@")
  parent_id = aws_organizations_organizational_unit.prod.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
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

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}

# --- Infrastructure OU ---
# network: Transit Gateway, egress/inspection VPC, Network Firewall, endpoints.
resource "aws_organizations_account" "network" {
  name      = "network"
  email     = replace(var.org_email_domain, "@", "+network@")
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}

# shared-services: private DNS resolver, future golden-image pipeline, tooling.
resource "aws_organizations_account" "shared_services" {
  name      = "shared-services"
  email     = replace(var.org_email_domain, "@", "+shared-services@")
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}

# log-archive: org CloudTrail (Object-Lock S3) and AWS Config delivery. Write-only
# from the rest of the org; the immutable record of what happened.
resource "aws_organizations_account" "log_archive" {
  name      = "log-archive"
  email     = replace(var.org_email_domain, "@", "+log-archive@")
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = true

  lifecycle {
    ignore_changes = [role_name]
  }
}
