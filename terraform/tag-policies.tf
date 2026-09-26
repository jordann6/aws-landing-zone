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
resource "aws_organizations_policy" "tag_policy" {
  name        = "require-allocation-tags"
  description = "Require and constrain the cost-allocation tags across the org"
  type        = "TAG_POLICY"
  content     = file("${path.module}/policies/tag-policy.json")
}

# Attached at the root so every account inherits it. The management account is
# exempt from SCPs by design but tag policies apply org-wide; that is fine, the
# management account holds no tagged workloads.
resource "aws_organizations_policy_attachment" "root_tag_policy" {
  policy_id = aws_organizations_policy.tag_policy.id
  target_id = aws_organizations_organization.org.roots[0].id
}
