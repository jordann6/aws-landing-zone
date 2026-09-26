# Human identity via IAM Identity Center. Personas are permission sets bound to
# groups; access to an account is a group membership, not a standing IAM user.
#
# Prerequisite: IAM Identity Center must be enabled in the org first (a one-time
# action Terraform cannot perform). Once enabled, this reads the instance. In
# production the groups are synced from the external IdP over SCIM; here they are
# created in the built-in identity store so the persona-by-scope matrix is real
# and reviewable. Set enable_identity_center=false to skip this layer entirely.

data "aws_ssoadmin_instances" "this" {
  count = var.enable_identity_center ? 1 : 0
}

locals {
  idc_enabled      = var.enable_identity_center
  idc_instance_arn = local.idc_enabled ? tolist(data.aws_ssoadmin_instances.this[0].arns)[0] : ""
  identity_store   = local.idc_enabled ? tolist(data.aws_ssoadmin_instances.this[0].identity_store_ids)[0] : ""

  # Account name -> id, for the assignment matrix. The gated accounts drop out
  # when full_account_set is false, and the assignment matrix below filters to
  # whatever accounts actually exist.
  accounts = merge(
    {
      management  = aws_organizations_organization.org.master_account_id
      security    = aws_organizations_account.security.id
      log_archive = aws_organizations_account.log_archive.id
      sandbox     = aws_organizations_account.sandbox.id
    },
    var.full_account_set ? {
      network         = one(aws_organizations_account.network[*].id)
      shared_services = one(aws_organizations_account.shared_services[*].id)
      dev             = one(aws_organizations_account.dev[*].id)
      test            = one(aws_organizations_account.test[*].id)
      prod            = one(aws_organizations_account.prod[*].id)
    } : {}
  )

  # Persona -> permission set. session_duration caps the credential lifetime;
  # prod-touching and break-glass personas get the shortest, so elevated access
  # is not left lying open. A managed permissions boundary caps the delegated
  # engineer personas below full admin regardless of the attached policy.
  permission_sets = {
    admin = {
      description  = "Full administrator (platform owners)"
      session      = "PT1H"
      managed      = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      boundary_arn = null
    }
    platform-eng = {
      description  = "Senior/platform engineer, capped below admin"
      session      = "PT4H"
      managed      = ["arn:aws:iam::aws:policy/PowerUserAccess"]
      boundary_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
    }
    junior-eng = {
      description  = "Junior engineer, read plus limited compute, capped"
      session      = "PT4H"
      managed      = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      boundary_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
    }
    manager = {
      description  = "Manager, view only"
      session      = "PT2H"
      managed      = ["arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"]
      boundary_arn = null
    }
    finops = {
      description  = "FinOps, billing and cost visibility"
      session      = "PT2H"
      managed      = ["arn:aws:iam::aws:policy/job-function/Billing"]
      boundary_arn = null
    }
    security = {
      description  = "Security, audit-level read across accounts"
      session      = "PT2H"
      managed      = ["arn:aws:iam::aws:policy/SecurityAudit"]
      boundary_arn = null
    }
    break-glass = {
      description  = "Sealed emergency admin, short session, alarmed on use"
      session      = "PT1H"
      managed      = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      boundary_arn = null
    }
  }

  # Representative persona-by-account assignments. The full matrix and the CIS
  # control each row satisfies live in docs/access-model.md.
  assignments_all = {
    "platform-eng:dev"  = { persona = "platform-eng", account = "dev" }
    "platform-eng:test" = { persona = "platform-eng", account = "test" }
    "junior-eng:dev"    = { persona = "junior-eng", account = "dev" }
    "manager:dev"       = { persona = "manager", account = "dev" }
    "manager:test"      = { persona = "manager", account = "test" }
    "manager:prod"      = { persona = "manager", account = "prod" }
    "admin:prod"        = { persona = "admin", account = "prod" }
    "admin:management"  = { persona = "admin", account = "management" }
    "finops:management" = { persona = "finops", account = "management" }
    "security:security" = { persona = "security", account = "security" }
    "security:dev"      = { persona = "security", account = "dev" }
    "security:test"     = { persona = "security", account = "test" }
    "security:prod"     = { persona = "security", account = "prod" }
    "breakglass:mgmt"   = { persona = "break-glass", account = "management" }
  }

  # Only assign to accounts that exist in this deployment (full_account_set may
  # gate dev/test/prod/network/shared-services off).
  assignments = {
    for k, v in local.assignments_all : k => v
    if contains(keys(local.accounts), v.account)
  }
}

resource "aws_identitystore_group" "persona" {
  for_each = local.idc_enabled ? local.permission_sets : {}

  identity_store_id = local.identity_store
  display_name      = each.key
  description       = each.value.description
}

resource "aws_ssoadmin_permission_set" "persona" {
  for_each = local.idc_enabled ? local.permission_sets : {}

  name             = each.key
  description      = each.value.description
  instance_arn     = local.idc_instance_arn
  session_duration = each.value.session
}

resource "aws_ssoadmin_managed_policy_attachment" "persona" {
  for_each = local.idc_enabled ? {
    for pair in flatten([
      for name, cfg in local.permission_sets : [
        for arn in cfg.managed : { key = "${name}:${arn}", ps = name, arn = arn }
      ]
    ]) : pair.key => pair
  } : {}

  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.persona[each.value.ps].arn
  managed_policy_arn = each.value.arn
}

resource "aws_ssoadmin_permissions_boundary_attachment" "persona" {
  for_each = local.idc_enabled ? {
    for name, cfg in local.permission_sets : name => cfg if cfg.boundary_arn != null
  } : {}

  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.persona[each.key].arn

  permissions_boundary {
    managed_policy_arn = each.value.boundary_arn
  }
}

resource "aws_ssoadmin_account_assignment" "persona" {
  for_each = local.idc_enabled ? local.assignments : {}

  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.persona[each.value.persona].arn

  principal_id   = aws_identitystore_group.persona[each.value.persona].group_id
  principal_type = "GROUP"

  target_id   = local.accounts[each.value.account]
  target_type = "AWS_ACCOUNT"
}
