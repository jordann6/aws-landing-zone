# Member accounts are permanent. They live in this root, which is never part of
# a teardown, so a destroy of the billable layers leaves every account ACTIVE.
#
# close_on_deletion = false: closing an account leaves it SUSPENDED for 90 days,
# still counted against the org account quota and still holding its email alias,
# so a redeploy collides with it. Idle accounts cost nothing.
#
# Retiring an account is therefore a two-step, by hand: move it to the Suspended
# OU (ous.tf), whose deny-all SCP freezes it immediately, then CloseAccount from
# the management account. Its block here is removed only after the 90 days.
# prevent_destroy: with close_on_deletion off, a destroy would try to remove the
# account from the org instead, which fails without standalone billing. Refusing
# the plan up front is the honest behavior.

# Account vending in miniature. Every member account is one entry in this map, so
# a new account is a one-line pull request that plans through the gated
# governance pipeline (apply-governance.yml): the reviewer sees exactly one
# aws_organizations_account to create before approving org-apply. The key is the
# account name and the email alias (org_email_domain with +<key>), so the two can
# never drift apart. See docs/accelerator-vs-bespoke.md for how this maps to
# Control Tower Account Factory / AFT.
#
#   ou       which OU the account lands in
#   gated    created only when full_account_set is true (dev, test, prod, network,
#            shared-services). Where the org is at its account limit, set
#            full_account_set=false to keep only security, log-archive and sandbox.
#   enabled  per-entry switch for accounts that are designed but not deployed
locals {
  accounts = {
    sandbox = { ou = aws_organizations_organizational_unit.sandbox.id, gated = false, enabled = true }
    dev     = { ou = aws_organizations_organizational_unit.dev.id, gated = true, enabled = true }
    test    = { ou = aws_organizations_organizational_unit.test.id, gated = true, enabled = true }
    prod    = { ou = aws_organizations_organizational_unit.prod.id, gated = true, enabled = true }
    # Delegated administrator for the org's detective services (Security Hub,
    # GuardDuty, IAM Access Analyzer), kept apart from the management account.
    security = { ou = aws_organizations_organizational_unit.security.id, gated = false, enabled = true }
    # Transit Gateway, inspection VPC, Network Firewall, endpoints.
    network = { ou = aws_organizations_organizational_unit.infrastructure.id, gated = true, enabled = true }
    # Private DNS resolver, CloudWatch OAM monitoring account, standing controls.
    "shared-services" = { ou = aws_organizations_organizational_unit.infrastructure.id, gated = true, enabled = true }
    # Org CloudTrail (Object Lock) and Config delivery; write-only from the rest
    # of the org.
    "log-archive" = { ou = aws_organizations_organizational_unit.infrastructure.id, gated = false, enabled = true }
    # A dedicated CI/CD account. Designed, not deployed: pipelines run in GitHub
    # Actions over OIDC, and the org is at 9 of its ~10 account quota.
    cicd = { ou = aws_organizations_organizational_unit.deployments.id, gated = true, enabled = var.deployments_account_enabled }
  }

  vended_accounts = {
    for name, a in local.accounts : name => a
    if a.enabled && (var.full_account_set || !a.gated)
  }
}

resource "aws_organizations_account" "this" {
  for_each = local.vended_accounts

  name      = each.key
  email     = replace(var.org_email_domain, "@", "+${each.key}@")
  parent_id = each.value.ou

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [role_name]
  }
}
