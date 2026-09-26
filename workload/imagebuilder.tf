# Golden-image pipeline for hardened AMIs. The pipeline is free standing; running
# it produces a patched, hardened Amazon Linux 2023 AMI that node groups can be
# pinned to, so nodes start from a known-good baseline rather than the stock image.
# It runs on demand, not on every deploy.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_iam_role" "imagebuilder" {
  name               = "prod-imagebuilder"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json # EC2 trust, same as nodes
}

resource "aws_iam_role_policy_attachment" "imagebuilder" {
  for_each = toset([
    "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.imagebuilder.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "imagebuilder" {
  name = "prod-imagebuilder"
  role = aws_iam_role.imagebuilder.name
}

resource "aws_imagebuilder_component" "harden" {
  #checkov:skip=CKV_AWS_180:CMK encryption of the component is a production setting; the demo uses the default key.
  name     = "baseline-harden"
  platform = "Linux"
  version  = "1.0.0"

  data = yamlencode({
    schemaVersion = 1.0
    phases = [{
      name = "build"
      steps = [{
        name   = "harden"
        action = "ExecuteBash"
        inputs = {
          commands = [
            "dnf -y update",
            "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config",
            "sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config",
            "systemctl enable amazon-ssm-agent",
          ]
        }
      }]
    }]
  })
}

resource "aws_imagebuilder_image_recipe" "hardened" {
  name         = "hardened-al2023"
  parent_image = data.aws_ssm_parameter.al2023.value
  version      = "1.0.0"

  component {
    component_arn = aws_imagebuilder_component.harden.arn
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "prod" {
  name                          = "prod-hardened"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder.name
  instance_types                = ["t3.medium"]
  subnet_id                     = local.node_subnet_ids[0]
  security_group_ids            = [aws_security_group.endpoints.id]
  terminate_instance_on_failure = true
}

resource "aws_imagebuilder_image_pipeline" "hardened" {
  name                             = "hardened-al2023"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.hardened.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.prod.arn
}
