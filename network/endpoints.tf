# Private connectivity to AWS services, so the registry, Secrets Manager, logging,
# and SSM are reached over private IPs with no internet path. SSM interface
# endpoints are what give Session Manager access with no bastion and no public SSH.

locals {
  interface_endpoints = [
    "ssm",         # Session Manager
    "ssmmessages", # Session Manager data channel
    "ec2messages", # SSM agent
    "ecr.api",     # ECR control plane
    "ecr.dkr",     # ECR image pulls
    "secretsmanager",
    "logs", # CloudWatch Logs
  ]
}

resource "aws_security_group" "endpoints" {
  name        = "hub-vpc-endpoints"
  description = "HTTPS from within the hub VPC to the interface endpoints"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description = "HTTPS from the hub VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr]
  }

  egress {
    description = "HTTPS responses within the hub VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.hub_cidr]
  }

  tags = { Name = "hub-vpc-endpoints" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.hub.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.this["endpoints"].id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "hub-${each.value}" }
}

# S3 over a gateway endpoint (free), attached to the route tables that need it.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.hub.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = [
    aws_route_table.endpoints.id,
    aws_route_table.firewall.id,
  ]

  tags = { Name = "hub-s3" }
}
