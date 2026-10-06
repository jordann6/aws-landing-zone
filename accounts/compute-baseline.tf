# Initial rollout is restricted to Sandbox. No attachment to Root or Workloads.
resource "aws_organizations_policy" "compute_scp" {
  for_each    = toset(["require-imdsv2", "require-encrypted-ebs"])
  name        = each.value
  description = "Sandbox compute baseline with sealed Identity Center break-glass exception"
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/policies/${each.value}.json.tftpl", {
    sandbox_account_id = aws_organizations_account.sandbox.id
  })
}
resource "aws_organizations_policy_attachment" "sandbox_compute_scp" {
  for_each  = aws_organizations_policy.compute_scp
  policy_id = each.value.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}
resource "aws_organizations_policy" "sandbox_ec2_baseline" {
  name        = "sandbox-ec2-baseline"
  description = "Sandbox EC2 defaults, allowed AMIs and public sharing controls"
  type        = "DECLARATIVE_POLICY_EC2"
  content = templatefile("${path.module}/policies/sandbox-ec2-baseline.json.tftpl", {
    # Golden AMIs are built and owned by the prod account (workload/imagebuilder.tf);
    # the criteria is omitted when the full account set is not vended.
    golden_ami_owner_account_id = one(aws_organizations_account.prod[*].id)
  })
  depends_on = [aws_organizations_organization.org]
}
resource "aws_organizations_policy_attachment" "sandbox_ec2_baseline" {
  policy_id = aws_organizations_policy.sandbox_ec2_baseline.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}
