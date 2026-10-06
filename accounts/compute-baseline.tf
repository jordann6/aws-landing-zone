# Compute baseline guardrails, attached to the Sandbox OU and the Workloads OU
# (inherited by Dev, Test and Prod). No attachment to Root: the Infrastructure
# and Security OUs run no general-purpose compute.

locals {
  # Accounts under the OUs the compute SCPs attach to. Each gets a sealed
  # Identity Center break-glass exemption; it is inert until the governance
  # root assigns the break-glass persona in that account.
  compute_baseline_account_ids = compact([
    aws_organizations_account.sandbox.id,
    one(aws_organizations_account.dev[*].id),
    one(aws_organizations_account.test[*].id),
    one(aws_organizations_account.prod[*].id),
  ])

  break_glass_principal_arns = flatten([
    for id in local.compute_baseline_account_ids : [
      "arn:aws:iam::${id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_break-glass_*",
      "arn:aws:iam::${id}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_break-glass_*",
    ]
  ])

  al2023_image_names = ["al2023-ami-*-x86_64"]

  # One declarative policy per OU from one template. Workloads adds the
  # EKS-optimized AL2023 node images (Amazon-owned, provider "amazon"), which the
  # managed node group launches. Unpinned minor so a cluster upgrade keeps working.
  ec2_baseline = {
    sandbox = {
      name                 = "sandbox-ec2-baseline"
      description          = "Sandbox EC2 defaults, allowed AMIs and public sharing controls"
      ou_label             = "Sandbox"
      target_id            = aws_organizations_organizational_unit.sandbox.id
      allowed_images_state = "enabled"
      amazon_image_names   = local.al2023_image_names
    }
    workloads = {
      name                 = "workloads-ec2-baseline"
      description          = "Workloads EC2 defaults, allowed AMIs and public sharing controls"
      ou_label             = "Workloads"
      target_id            = aws_organizations_organizational_unit.workloads.id
      allowed_images_state = var.workloads_allowed_images_state
      amazon_image_names   = concat(local.al2023_image_names, ["amazon-eks-node-al2023-x86_64-standard-*"])
    }
  }
}

resource "aws_organizations_policy" "compute_scp" {
  for_each    = toset(["require-imdsv2", "require-encrypted-ebs"])
  name        = each.value
  description = "Compute baseline with sealed Identity Center break-glass exception"
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/policies/${each.value}.json.tftpl", {
    break_glass_principal_arns = jsonencode(local.break_glass_principal_arns)
  })
}

resource "aws_organizations_policy_attachment" "sandbox_compute_scp" {
  for_each  = aws_organizations_policy.compute_scp
  policy_id = each.value.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}

resource "aws_organizations_policy_attachment" "workloads_compute_scp" {
  for_each  = aws_organizations_policy.compute_scp
  policy_id = each.value.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "ec2_baseline" {
  for_each    = local.ec2_baseline
  name        = each.value.name
  description = each.value.description
  type        = "DECLARATIVE_POLICY_EC2"
  content = templatefile("${path.module}/policies/ec2-baseline.json.tftpl", {
    ou_label             = each.value.ou_label
    allowed_images_state = each.value.allowed_images_state
    amazon_image_names   = jsonencode(each.value.amazon_image_names)
    # Golden AMIs are built and owned by the prod account (workload/imagebuilder.tf);
    # the criteria is omitted when the full account set is not vended.
    golden_ami_owner_account_id = one(aws_organizations_account.prod[*].id)
  })
  depends_on = [aws_organizations_organization.org]
}

resource "aws_organizations_policy_attachment" "ec2_baseline" {
  for_each  = local.ec2_baseline
  policy_id = aws_organizations_policy.ec2_baseline[each.key].id
  target_id = each.value.target_id
}

moved {
  from = aws_organizations_policy.sandbox_ec2_baseline
  to   = aws_organizations_policy.ec2_baseline["sandbox"]
}

moved {
  from = aws_organizations_policy_attachment.sandbox_ec2_baseline
  to   = aws_organizations_policy_attachment.ec2_baseline["sandbox"]
}
