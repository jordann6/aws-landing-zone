resource "aws_organizations_policy" "deny_leave_org" {
  name        = "deny-leave-org"
  description = "Prevent member accounts from leaving the organization"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-leave-org.json")
}

resource "aws_organizations_policy" "deny_root_user" {
  name        = "deny-root-user"
  description = "Block all actions by the root user in member accounts"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-root-user.json")
}

locals {
  # Global services stay reachable from any region.
  region_exempt_actions = [
    "budgets:*", "ce:*", "cloudfront:*", "cur:*", "globalaccelerator:*", "health:*",
    "iam:*", "organizations:*", "pricing:*", "route53:*", "route53domains:*",
    "s3:GetAccountPublic*", "s3:ListAllMyBuckets", "s3:PutAccountPublic*", "shield:*",
    "sts:*", "support:*", "trustedadvisor:*", "waf:*", "wafv2:*",
  ]
  # Phase D: the standby region is allowed by the first statement and then denied
  # again to every account except prod by the second, so only prod can use it.
  standby_enabled = var.standby_region != ""
}

resource "aws_organizations_policy" "region_lockdown" {
  name        = "region-lockdown"
  description = "Restrict API calls to approved regions only"
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/policies/region-lockdown.json.tftpl", {
    exempt_actions     = jsonencode(local.region_exempt_actions)
    allowed_regions    = jsonencode(local.standby_enabled ? concat(var.allowed_regions, [var.standby_region]) : var.allowed_regions)
    standby_region     = var.standby_region
    standby_account_id = local.standby_enabled ? try(aws_organizations_account.this["prod"].id, null) : ""
  })
}

resource "aws_organizations_policy" "require_s3_encryption" {
  name        = "require-s3-encryption"
  description = "Deny S3 PutObject without server-side encryption header"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/require-s3-encryption.json")
}

resource "aws_organizations_policy" "deny_public_s3" {
  name        = "deny-public-s3"
  description = "Prevent public S3 bucket ACLs and removal of account public access block"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-public-s3.json")
}

resource "aws_organizations_policy" "deny_all" {
  name        = "deny-all"
  description = "Freeze every principal in an account awaiting closure (Suspended OU only)"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-all.json")
}

resource "aws_organizations_policy" "deny_disable_detective" {
  name        = "deny-disable-detective"
  description = "Prevent disabling Config, GuardDuty, Security Hub, Access Analyzer, or tampering with CloudTrail"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-disable-detective.json")
}

# --- Root-level attachments (all member accounts) ---

resource "aws_organizations_policy_attachment" "root_deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = aws_organizations_organization.org.roots[0].id
}

resource "aws_organizations_policy_attachment" "root_deny_root_user" {
  policy_id = aws_organizations_policy.deny_root_user.id
  target_id = aws_organizations_organization.org.roots[0].id
}

# Detective services are org-wide, so the "do not turn them off" guard is too.
#
# CloudTrail is a detective control, so its tamper guard is a statement in this
# same policy (DenyCloudTrailTampering) rather than a policy of its own: the root
# is at the 5-SCP-per-target limit (FullAWSAccess, deny-root-user, deny-leave-org,
# this, deny-public-s3). It used to be a separate policy on Prod only, which left
# the claim in terraform/logging.tf true for one OU. The org trail itself lives
# in the management account, which no SCP binds; the statement covers every
# member principal and every member-owned trail. OrganizationAccountAccessRole is
# its one exemption: the operator's break-glass role, every use of it lands in the
# org trail, and without it a member-owned trail (the secrets scanner's
# secops-trail in security) could never be torn down. The CI gha-apply roles are
# not exempt.
# The Config statement carries the same single exemption (added 2026-11-20). A
# member recorder that a lab created, or one left by a failed teardown (prod's
# selfheal-recorder from 11/4), could otherwise never be removed, and AWS allows
# only one recorder per account and region, so it blocked the org-standard
# recorder. CI and Identity Center personas still cannot stop or delete Config.
resource "aws_organizations_policy_attachment" "root_deny_disable_detective" {
  policy_id = aws_organizations_policy.deny_disable_detective.id
  target_id = aws_organizations_organization.org.roots[0].id
}

# No member account may make a bucket public by ACL, and only the break-glass role
# may change the account-level S3 public access block (so it can be set once per
# account, never loosened by a workload or CI role). Root, not Prod only: a public
# bucket in dev or sandbox leaks the same data.
resource "aws_organizations_policy_attachment" "root_deny_public_s3" {
  policy_id = aws_organizations_policy.deny_public_s3.id
  target_id = aws_organizations_organization.org.roots[0].id
}

# --- Security OU ---
# Region lockdown was missing here. Every detective service the security account
# runs (GuardDuty, Security Hub, Config, the forensics and secrets-scanner
# Lambdas) is in us-east-1 only, verified across all 17 regions on 2026-11-20, and
# the global services are already exempt, so nothing it does needs another region.
resource "aws_organizations_policy_attachment" "security_region_lockdown" {
  policy_id = aws_organizations_policy.region_lockdown.id
  target_id = aws_organizations_organizational_unit.security.id
}

# --- Infrastructure OU (network, shared-services, log-archive) ---

resource "aws_organizations_policy_attachment" "infrastructure_region_lockdown" {
  policy_id = aws_organizations_policy.region_lockdown.id
  target_id = aws_organizations_organizational_unit.infrastructure.id
}

resource "aws_organizations_policy_attachment" "infrastructure_require_s3_encryption" {
  policy_id = aws_organizations_policy.require_s3_encryption.id
  target_id = aws_organizations_organizational_unit.infrastructure.id
}

# --- Sandbox OU ---

resource "aws_organizations_policy_attachment" "sandbox_region_lockdown" {
  policy_id = aws_organizations_policy.region_lockdown.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}

# --- Workloads OU (inherited by Dev + Prod) ---

resource "aws_organizations_policy_attachment" "workloads_region_lockdown" {
  policy_id = aws_organizations_policy.region_lockdown.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy_attachment" "workloads_require_s3_encryption" {
  policy_id = aws_organizations_policy.require_s3_encryption.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

# --- Prod OU ---
# Prod's extra restrictions are the EC2 baseline and golden-image policies in
# compute-baseline.tf. The trail and public-S3 guards it used to carry alone now
# sit at the root and reach Prod by inheritance.

# --- Suspended OU ---
# Deny-all, attached here and nowhere else. Moving an account in is the freeze;
# moving it out (a management-account action) reverses it.
resource "aws_organizations_policy_attachment" "suspended_deny_all" {
  policy_id = aws_organizations_policy.deny_all.id
  target_id = aws_organizations_organizational_unit.suspended.id
}

# --- Deployments OU ---
# Empty today; any CI account placed here is region-locked like every other OU
# with member accounts.
resource "aws_organizations_policy_attachment" "deployments_region_lockdown" {
  policy_id = aws_organizations_policy.region_lockdown.id
  target_id = aws_organizations_organizational_unit.deployments.id
}
