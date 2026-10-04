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

resource "aws_organizations_policy" "region_lockdown" {
  name        = "region-lockdown"
  description = "Restrict API calls to approved regions only"
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/policies/region-lockdown.json.tftpl", {
    allowed_regions = jsonencode(var.allowed_regions)
  })
}

resource "aws_organizations_policy" "require_s3_encryption" {
  name        = "require-s3-encryption"
  description = "Deny S3 PutObject without server-side encryption header"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/require-s3-encryption.json")
}

resource "aws_organizations_policy" "deny_cloudtrail_tampering" {
  name        = "deny-cloudtrail-tampering"
  description = "Prevent stopping, deleting, or modifying CloudTrail trails"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-cloudtrail-tampering.json")
}

resource "aws_organizations_policy" "deny_public_s3" {
  name        = "deny-public-s3"
  description = "Prevent public S3 bucket ACLs and removal of account public access block"
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/policies/deny-public-s3.json")
}

resource "aws_organizations_policy" "deny_disable_detective" {
  name        = "deny-disable-detective"
  description = "Prevent disabling Config, GuardDuty, Security Hub, or Access Analyzer"
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
resource "aws_organizations_policy_attachment" "root_deny_disable_detective" {
  policy_id = aws_organizations_policy.deny_disable_detective.id
  target_id = aws_organizations_organization.org.roots[0].id
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

# --- Prod OU (additional restrictions) ---

resource "aws_organizations_policy_attachment" "prod_deny_cloudtrail_tampering" {
  policy_id = aws_organizations_policy.deny_cloudtrail_tampering.id
  target_id = aws_organizations_organizational_unit.prod.id
}

resource "aws_organizations_policy_attachment" "prod_deny_public_s3" {
  policy_id = aws_organizations_policy.deny_public_s3.id
  target_id = aws_organizations_organizational_unit.prod.id
}
