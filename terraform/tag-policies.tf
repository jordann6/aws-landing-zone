# Organization tag policy. SCPs govern actions; a tag policy governs metadata, so
# spend stays attributable. It defines the allocation keys (CostCenter, Owner,
# Environment, DataClassification), pins the values Environment and
# DataClassification may take, and enforces the CostCenter key on the resource
# types most likely to carry cost, so a create with a missing or mistyped key is
# rejected rather than landing in the unallocated bucket.
#
# This is the preventive twin of the FinOps OPA gate: OPA catches it at PR time
# from the HCL, the tag policy catches it at runtime from any path (console, CLI,
# a module the policy could not read statically).
#
# Gated by enable_tag_policy so the governance core can deploy where the tag
# policy document or the TAG_POLICY type still needs work.
resource "aws_organizations_policy" "tag_policy" {
  count       = var.enable_tag_policy ? 1 : 0
  name        = "require-allocation-tags"
  description = "Require and constrain the cost-allocation tags across the org"
  type        = "TAG_POLICY"
  content     = file("${path.module}/policies/tag-policy.json")
}

# Attached at the root so every account inherits it. The management account is
# exempt from SCPs by design but tag policies apply org-wide; that is fine, the
# management account holds no tagged workloads.
resource "aws_organizations_policy_attachment" "root_tag_policy" {
  count     = var.enable_tag_policy ? 1 : 0
  policy_id = aws_organizations_policy.tag_policy[0].id
  target_id = aws_organizations_organization.org.roots[0].id
}
