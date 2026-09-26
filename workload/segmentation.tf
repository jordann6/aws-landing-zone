# Data-tier segmentation. Two layers enforce "only the app tier reaches the DB,
# on its port": stateful security groups (the primary control) and a stateless
# NACL on the data subnets (defense in depth). Cross-environment isolation
# (dev/test/prod data tiers cannot reach each other) is enforced above this by
# account and VPC separation: the tiers are separate VPCs with no peering, and
# the hub TGW does not route spoke to spoke.

locals {
  app_cidrs = [local.subnets.app_a.cidr, local.subnets.app_b.cidr]
  db_port   = 5432
}

#trivy:ignore:AVD-AWS-0104:Egress to 0.0.0.0/0 on 443 is intentional; the hub Network Firewall (not this SG) enforces the destination allowlist.
resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Attached by the app/EKS workload tier in Phase 6; referenced here by the DB ingress rule.
  name        = "prod-app"
  description = "Application tier"
  vpc_id      = aws_vpc.prod.id

  egress {
    description = "HTTPS egress (inspected at the hub firewall via the TGW)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.prod_cidr]
  }

  tags = { Name = "prod-app" }
}

resource "aws_security_group" "db" {
  name        = "prod-db"
  description = "Database tier: reachable only from the app tier on the DB port"
  vpc_id      = aws_vpc.prod.id

  ingress {
    description     = "PostgreSQL from the app tier only"
    from_port       = local.db_port
    to_port         = local.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "Responses to the app tier"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.prod_cidr]
  }

  tags = { Name = "prod-db" }
}

# NACL on the data subnets: only the app subnets may reach them, and only on the
# DB port plus ephemeral return. Everything else is denied at the subnet edge.
resource "aws_network_acl" "data" {
  #checkov:skip=CKV2_AWS_1:The NACL is attached to the data subnets via subnet_ids on this resource.
  vpc_id     = aws_vpc.prod.id
  subnet_ids = local.data_subnet_ids
  tags       = { Name = "prod-data" }
}

resource "aws_network_acl_rule" "data_in_db" {
  count = length(local.app_cidrs)

  network_acl_id = aws_network_acl.data.id
  rule_number    = 100 + count.index
  egress         = false
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = local.app_cidrs[count.index]
  from_port      = local.db_port
  to_port        = local.db_port
}

resource "aws_network_acl_rule" "data_out_ephemeral" {
  network_acl_id = aws_network_acl.data.id
  rule_number    = 100
  egress         = true
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = var.prod_cidr
  from_port      = 1024
  to_port        = 65535
}
