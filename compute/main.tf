# The hardened management instance. Every landing zone runs one: built from that
# zone's golden image, no public IP, reachable only through the cloud-native
# path (here SSM Session Manager over the workload's interface endpoints), and
# patched by the zone's patch service. It is also the quarantine target of the
# forensics runbook (aws-incident-forensics, wired through the incident/ root).

locals {
  workload = data.terraform_remote_state.workload.outputs
  name     = "lz-mgmt"
}

# Golden AMIs from this account's Image Builder pipeline, newest first. aws_ami_ids
# returns an empty list instead of failing, so the precondition below can give a
# useful message when no image has been built yet.
data "aws_ami_ids" "golden" {
  owners = ["self"]

  filter {
    name   = "name"
    values = ["${local.workload.golden_image_name}-*"]
  }

  filter {
    name   = "tag:GoldenImage"
    values = ["true"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  golden_ami_id = try(data.aws_ami_ids.golden.ids[0], null)
}

# --- identity: SSM only ----------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "management" {
  count              = var.enable_management_instance ? 1 : 0
  name               = "prod-${local.name}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  # The forensics runbook may revoke sessions only on roles under this path, so
  # the path is the containment boundary. Its revoke step adds an inline deny
  # that is not in state; force_detach lets destroy remove it.
  path                  = "/lz-compute/"
  force_detach_policies = true
}

resource "aws_iam_role_policy_attachment" "management_ssm" {
  count      = var.enable_management_instance ? 1 : 0
  role       = aws_iam_role.management[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "management" {
  count = var.enable_management_instance ? 1 : 0
  name  = "prod-${local.name}"
  role  = aws_iam_role.management[0].name
}

# --- network: no inbound at all ---------------------------------------------------

resource "aws_security_group" "management" {
  #checkov:skip=CKV2_AWS_5:Attached to aws_instance.management; checkov cannot follow the count index.
  count       = var.enable_management_instance ? 1 : 0
  name        = "prod-${local.name}"
  description = "Management instance: no inbound; HTTPS to the VPC endpoints and S3 only"
  vpc_id      = local.workload.prod_vpc_id

  egress {
    description = "HTTPS to the interface endpoints (ssm, ssmmessages, ec2messages, logs)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.workload.prod_cidr]
  }

  egress {
    description     = "HTTPS to S3 for AL2023 patches and SSM documents"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [local.workload.s3_prefix_list_id]
  }

  tags = { Name = "prod-${local.name}" }
}

# --- the instance --------------------------------------------------------------

resource "aws_instance" "management" {
  count                       = var.enable_management_instance ? 1 : 0
  ami                         = local.golden_ami_id
  instance_type               = var.instance_type
  subnet_id                   = local.workload.app_subnet_ids[0]
  vpc_security_group_ids      = [aws_security_group.management[0].id]
  iam_instance_profile        = aws_iam_instance_profile.management[0].name
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true
  # No key_name: there is no SSH key anywhere. Access is SSM Session Manager.

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = local.workload.ebs_kms_key_arn
    delete_on_termination = true
    tags = {
      Name               = "prod-${local.name}-root"
      CostCenter         = var.cost_center
      Environment        = "prod"
      DataClassification = "internal"
    }
  }

  tags = {
    Name          = "prod-${local.name}"
    "Patch Group" = "prod"
    Role          = "management"
  }

  lifecycle {
    precondition {
      condition     = local.golden_ami_id != null
      error_message = "No golden AMI found. Run `make build-image` before `make deploy-compute`."
    }
    # A newer golden AMI should not silently replace a running management host;
    # redeploy compute to pick it up.
    ignore_changes = [ami]
  }
}
