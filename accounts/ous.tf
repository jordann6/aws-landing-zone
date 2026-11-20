resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.org.roots[0].id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = aws_organizations_organization.org.roots[0].id
}

resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = aws_organizations_organization.org.roots[0].id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.org.roots[0].id
}

resource "aws_organizations_organizational_unit" "dev" {
  name      = "Dev"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "test" {
  name      = "Test"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "prod" {
  name      = "Prod"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

# Account lifecycle. An account leaving service is moved here first: the deny-all
# SCP freezes every principal in it (root included, which deny-root-user already
# covers), so nothing can run, change or spend while it waits. Closing it is then
# a management-account action (organizations:CloseAccount), which no SCP binds, so
# the freeze never blocks the close. After CloseAccount the account sits SUSPENDED
# for 90 days, still in this OU and still counted against the account quota.
resource "aws_organizations_organizational_unit" "suspended" {
  name      = "Suspended"
  parent_id = aws_organizations_organization.org.roots[0].id
}

# Where a dedicated CI/CD account would live. Empty by default: this zone's
# pipelines run in GitHub Actions and reach AWS over OIDC through the gha-plan /
# gha-apply roles in bootstrap/, so there is no build fleet to host. An account
# placed here still inherits the root guards plus region lockdown.
resource "aws_organizations_organizational_unit" "deployments" {
  name      = "Deployments"
  parent_id = aws_organizations_organization.org.roots[0].id
}
