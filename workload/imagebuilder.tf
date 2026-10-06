# Golden-image pipeline. One hardening role, three image pipelines: this bakes the
# same cis_baseline Ansible role that the Azure (Compute Gallery) and GCP pipelines
# bake, on top of Amazon's STIG component, into an encrypted Amazon Linux 2023 AMI.
# The build runs in a private subnet with no internet path. The role and its
# collection are staged to S3 by `make stage-role` (pinned tag, read back through
# the S3 gateway endpoint), and the AL2023 package repos are also S3-backed.
#
# The test phase boots a fresh instance from the new AMI and runs the role's own
# check-hardening.sh, so an AMI is only distributed if the hardening survived a
# reboot. EKS nodes do not use this image (see eks.tf); it is for standalone
# instances such as the management instance in compute/.

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  golden_image_name = "lz-hardened-al2023"
  # Image Builder versions are immutable. major.minor follow the role; the patch
  # is the role patch x 100 plus this wrapper's revision (role 2.0.1, rev 1 =
  # 2.0.101). Bump component_revision whenever the component document changes.
  component_revision    = 3
  role_semver           = split(".", trimprefix(var.cis_baseline_release, "v"))
  cis_component_version = format("%s.%s.%d", local.role_semver[0], local.role_semver[1], tonumber(local.role_semver[2]) * 100 + local.component_revision)
  role_prefix           = "cis-baseline/${var.cis_baseline_release}"

  # Runs after the role. STIG and the role overlap in two places, and in both
  # the role must win (it carries the settings the cross-cloud test checks).
  reconcile_stig = <<-EOT
    set -euo pipefail
    # 1. sysctl: STIG writes /etc/sysctl.d/99-sysctl.conf, which sorts after the
    #    role's 99-hardening.conf and so wins at boot. Drop every key the role
    #    sets from STIG's files.
    for f in /etc/sysctl.d/99-sysctl.conf /etc/sysctl.conf; do
      [ -f "$f" ] || continue
      awk -F= '
        { key = $1; gsub(/[[:space:]]/, "", key) }
        NR == FNR { if (key ~ /^[a-z]/) role[key] = 1; next }
        key in role { print "role overrides STIG in " FILENAME ": " $0 > "/dev/stderr"; next }
        { print }' /etc/sysctl.d/99-hardening.conf "$f" > /tmp/lz-sysctl
      cat /tmp/lz-sysctl > "$f" # cat keeps the symlink and the file mode
    done
    rm -f /tmp/lz-sysctl
    sysctl --system > /dev/null
    # 2. audit: augenrules always emits -e 2 last, so one rule the kernel rejects
    #    (STIG re-adds rules the role already loads: "Rule exists") stops the
    #    load before the rules go immutable, and STIG's own reload discards that
    #    error. Load the merged rules without -e; on each rejected line, drop it
    #    from STIG's file (the role's copy stays) and retry until clean.
    for attempt in $(seq 1 25); do
      augenrules > /dev/null
      grep -v '^-e' /etc/audit/audit.rules > /tmp/lz-audit.rules
      auditctl -D > /dev/null
      if err="$(auditctl -R /tmp/lz-audit.rules 2>&1 > /dev/null)"; then break; fi
      n="$(echo "$err" | sed -n 's/.*error in line \([0-9][0-9]*\).*/\1/p' | head -1)"
      rule="$(sed -n "$n"p /tmp/lz-audit.rules)"
      reason="$(echo "$err" | grep -v 'slower$' | head -1)" # skip auditctl performance warnings
      if [ -z "$n" ] || ! grep -Fxq -- "$rule" /etc/audit/rules.d/audit.rules || [ "$attempt" -eq 25 ]; then
        echo "audit rules do not load cleanly and the rejected rule is not STIG's: $reason: $rule"
        exit 1
      fi
      echo "dropping STIG audit rule ($reason): $rule"
      grep -Fxv -- "$rule" /etc/audit/rules.d/audit.rules > /tmp/lz-stig.rules || true
      cat /tmp/lz-stig.rules > /etc/audit/rules.d/audit.rules
    done
    rm -f /tmp/lz-audit.rules /tmp/lz-stig.rules
    augenrules --load
    auditctl -s
  EOT

  # Never fails: puts the boot-time audit and sysctl state in the build log, so
  # a test failure can be diagnosed after Image Builder terminates the instance.
  boot_diagnostics = <<-EOT
    echo "--- auditctl -s"; auditctl -s || true
    echo "--- audit load errors this boot"
    journalctl -b --no-pager -u auditd -u audit-rules 2>&1 | grep -i -E 'error|fail|line' || echo none
    echo "--- sysctl"; sysctl kernel.kptr_restrict || true
  EOT
}

# --- staged role artifacts ---------------------------------------------------

#trivy:ignore:AVD-AWS-0089:Access logging for a two-object build artifact bucket adds a second bucket with no audit value; CloudTrail data events cover reads.
resource "aws_s3_bucket" "imagebuilder_artifacts" {
  #checkov:skip=CKV_AWS_18:Access logging for a two-object build artifact bucket adds a second bucket with no audit value; CloudTrail covers reads.
  #checkov:skip=CKV_AWS_144:Artifacts are re-staged from the pinned git tag; cross-region replication adds cost with no recovery value.
  #checkov:skip=CKV_AWS_145:SSE-S3 is deliberate; the build role reads through the S3 gateway endpoint and needs no KMS grant.
  #checkov:skip=CKV2_AWS_62:No consumer reacts to artifact uploads; event notifications are not needed.
  bucket        = "prod-imagebuilder-artifacts-${data.aws_caller_identity.prod.account_id}"
  force_destroy = true # staged copies of a public git tag; teardown must not block on them
  tags          = { Name = "prod-imagebuilder-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "imagebuilder_artifacts" {
  bucket                  = aws_s3_bucket.imagebuilder_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "imagebuilder_artifacts" {
  bucket = aws_s3_bucket.imagebuilder_artifacts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "imagebuilder_artifacts" {
  bucket = aws_s3_bucket.imagebuilder_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

#trivy:ignore:AVD-AWS-0132:SSE-S3 is deliberate; the build role reads through the S3 gateway endpoint and needs no KMS grant.
resource "aws_s3_bucket_server_side_encryption_configuration" "imagebuilder_artifacts" {
  bucket = aws_s3_bucket.imagebuilder_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "imagebuilder_artifacts" {
  bucket = aws_s3_bucket.imagebuilder_artifacts.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "imagebuilder_artifacts" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.imagebuilder_artifacts.arn, "${aws_s3_bucket.imagebuilder_artifacts.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "imagebuilder_artifacts" {
  bucket     = aws_s3_bucket.imagebuilder_artifacts.id
  policy     = data.aws_iam_policy_document.imagebuilder_artifacts.json
  depends_on = [aws_s3_bucket_public_access_block.imagebuilder_artifacts]
}

# --- build instance identity and network ---------------------------------------

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

data "aws_iam_policy_document" "imagebuilder_read_role" {
  statement {
    sid       = "ReadStagedRole"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.imagebuilder_artifacts.arn}/cis-baseline/*"]
  }
}

resource "aws_iam_role_policy" "imagebuilder_read_role" {
  name   = "read-staged-role"
  role   = aws_iam_role.imagebuilder.id
  policy = data.aws_iam_policy_document.imagebuilder_read_role.json
}

resource "aws_iam_instance_profile" "imagebuilder" {
  name = "prod-imagebuilder"
  role = aws_iam_role.imagebuilder.name
}

# Build and test instances only talk to the in-VPC endpoints and to S3 (role
# bundle, AL2023 repos, Image Builder component documents) through the gateway
# endpoint. No inbound rules: Image Builder drives the instance through SSM.
resource "aws_security_group" "imagebuilder" {
  name        = "prod-imagebuilder"
  description = "Golden image build and test instances: egress to endpoints and S3 only"
  vpc_id      = aws_vpc.prod.id

  egress {
    description = "HTTPS to the interface endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.prod_cidr]
  }

  egress {
    description     = "HTTPS to S3 through the gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]
  }

  tags = { Name = "prod-imagebuilder" }
}

# --- components and recipe -----------------------------------------------------

resource "aws_imagebuilder_component" "cis_baseline" {
  #checkov:skip=CKV_AWS_180:Component documents hold no secrets (a public role tag and shell steps); the default Image Builder key is sufficient.
  name        = "cis-baseline"
  description = "Shared cis_baseline Ansible role ${var.cis_baseline_release}, applied offline from S3, then verified after reboot"
  platform    = "Linux"
  version     = local.cis_component_version

  lifecycle {
    create_before_destroy = true # the recipe in use must exist until the new one does
  }

  data = yamlencode({
    schemaVersion = 1.0
    phases = [
      {
        name = "build"
        steps = [
          {
            name   = "patch"
            action = "ExecuteBash"
            inputs = { commands = ["dnf -y upgrade --refresh"] }
          },
          {
            name   = "download-role"
            action = "S3Download"
            inputs = [{
              source      = "s3://${aws_s3_bucket.imagebuilder_artifacts.id}/${local.role_prefix}/bundle.tar.gz"
              destination = "/tmp/cis-baseline/bundle.tar.gz"
            }]
          },
          {
            name   = "apply-role"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "set -euo pipefail",
                "dnf -y install ansible-core tar",
                "cd /tmp/cis-baseline && tar -xzf bundle.tar.gz",
                "cd /tmp/cis-baseline/bundle/collections && ansible-galaxy collection install --offline -r requirements.yml -p /tmp/cis-baseline",
                "ANSIBLE_COLLECTIONS_PATH=/tmp/cis-baseline ansible-playbook -i localhost, -c local /tmp/cis-baseline/bundle/ansible/site.yml",
                "install -m 0700 -o root -g root /tmp/cis-baseline/bundle/scripts/check-hardening.sh /usr/local/sbin/check-hardening.sh",
                "dnf -y remove ansible-core",
                "rm -rf /tmp/cis-baseline",
              ]
            }
          },
          {
            name   = "reconcile-stig"
            action = "ExecuteBash"
            inputs = { commands = [local.reconcile_stig] }
          },
        ]
      },
      {
        # Runs on a fresh instance booted from the new AMI, after a reboot, so
        # immutable audit rules and persisted sysctls are checked as they boot.
        name = "test"
        steps = [
          {
            name   = "boot-diagnostics"
            action = "ExecuteBash"
            inputs = { commands = [local.boot_diagnostics] }
          },
          {
            name   = "check-hardening"
            action = "ExecuteBash"
            inputs = { commands = ["/usr/local/sbin/check-hardening.sh"] }
          },
        ]
      },
    ]
  })
}

resource "aws_imagebuilder_image_recipe" "hardened" {
  name         = local.golden_image_name
  parent_image = data.aws_ssm_parameter.al2023.value
  version      = local.cis_component_version
  description  = "AL2023 + Amazon STIG ${var.stig_component_level} + cis_baseline ${var.cis_baseline_release}"

  lifecycle {
    create_before_destroy = true # the pipeline points at it until the new version exists
  }

  # STIG first, then the shared role, so the role's settings (the ones the test
  # phase checks, identically on all three clouds) win any overlap.
  # The per-level components (stig-build-linux-medium) are deprecated and cannot
  # go into new recipes; the unified component takes the level as a parameter.
  component {
    component_arn = "arn:aws:imagebuilder:${var.region}:aws:component/stig-build-linux/x.x.x"

    parameter {
      name  = "Level"
      value = title(var.stig_component_level)
    }
  }

  component {
    component_arn = aws_imagebuilder_component.cis_baseline.arn
  }

  block_device_mapping {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 10
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }
}

resource "aws_imagebuilder_infrastructure_configuration" "prod" {
  name                          = "prod-hardened"
  description                   = "Private build: app subnet, no public IP, IMDSv2 only"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder.name
  instance_types                = [var.imagebuilder_instance_type]
  subnet_id                     = aws_subnet.this["app_a"].id
  security_group_ids            = [aws_security_group.imagebuilder.id]
  terminate_instance_on_failure = true

  instance_metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}

resource "aws_imagebuilder_distribution_configuration" "hardened" {
  name = local.golden_image_name

  distribution {
    region = var.region

    ami_distribution_configuration {
      name       = "${local.golden_image_name}-{{ imagebuilder:buildDate }}"
      kms_key_id = aws_kms_key.ebs.arn
      ami_tags = {
        Name               = local.golden_image_name
        GoldenImage        = "true"
        CisBaseline        = var.cis_baseline_release
        StigLevel          = var.stig_component_level
        Project            = "aws-landing-zone"
        Environment        = "prod"
        Owner              = var.owner
        CostCenter         = var.cost_center
        DataClassification = "internal"
      }

      dynamic "launch_permission" {
        for_each = var.organization_arn == null ? [] : [var.organization_arn]
        content {
          organization_arns = [launch_permission.value]
        }
      }
    }
  }
}

resource "aws_imagebuilder_image_pipeline" "hardened" {
  name                             = local.golden_image_name
  description                      = "On-demand golden AMI build (make build-image); no schedule"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.hardened.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.prod.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.hardened.arn
  enhanced_image_metadata_enabled  = true

  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes     = 60
  }

  # Inspector scans the AMI build for CVEs (Inspector is enabled org-wide).
  image_scanning_configuration {
    image_scanning_enabled = true
  }
}

# --- lifecycle: keep the newest image usable, retire the rest -------------------

data "aws_iam_policy_document" "imagebuilder_lifecycle_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["imagebuilder.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "imagebuilder_lifecycle" {
  name               = "prod-imagebuilder-lifecycle"
  assume_role_policy = data.aws_iam_policy_document.imagebuilder_lifecycle_assume.json
}

resource "aws_iam_role_policy_attachment" "imagebuilder_lifecycle" {
  role       = aws_iam_role.imagebuilder_lifecycle.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/EC2ImageBuilderLifecycleExecutionPolicy"
}

resource "aws_imagebuilder_lifecycle_policy" "hardened" {
  name           = local.golden_image_name
  description    = "Deprecate golden AMIs after 7 days and delete after 30, always keeping the newest"
  execution_role = aws_iam_role.imagebuilder_lifecycle.arn
  resource_type  = "AMI_IMAGE"

  # DEPRECATE accepts only an AGE filter, so both rules age out and
  # retain_at_least keeps the newest image usable (and three on disk).
  policy_detail {
    action {
      type = "DEPRECATE"
    }
    filter {
      type            = "AGE"
      value           = 7
      unit            = "DAYS"
      retain_at_least = 1
    }
  }

  policy_detail {
    action {
      type = "DELETE"
      include_resources {
        amis      = true
        snapshots = true
      }
    }
    filter {
      type            = "AGE"
      value           = 30
      unit            = "DAYS"
      retain_at_least = 3
    }
  }

  resource_selection {
    recipe {
      name             = aws_imagebuilder_image_recipe.hardened.name
      semantic_version = aws_imagebuilder_image_recipe.hardened.version
    }
  }

  depends_on = [aws_iam_role_policy_attachment.imagebuilder_lifecycle]
}
