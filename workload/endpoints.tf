# Interface endpoints for the private cluster. With no NAT, nodes reach ECR,
# STS, CloudWatch, and the EKS/EC2 control APIs over these private endpoints. The
# S3 gateway endpoint carries the ECR image layers (which live in S3). This is
# what lets the cluster pull images with no internet path at all.

locals {
  workload_interface_endpoints = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "ec2",
    "elasticloadbalancing",
    "logs",
    "monitoring", # CloudWatch metrics API for the Container Insights agent
    "eks",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
    "imagebuilder", # AWSTOE on the golden image build instance fetches components via this API
  ]
}

resource "aws_security_group" "endpoints" {
  name        = "prod-vpc-endpoints"
  description = "HTTPS from within the prod VPC to the interface endpoints"
  vpc_id      = aws_vpc.prod.id

  ingress {
    description = "HTTPS from the prod VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.prod_cidr]
  }

  egress {
    description = "HTTPS responses within the prod VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.prod_cidr]
  }

  tags = { Name = "prod-vpc-endpoints" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.workload_interface_endpoints)

  vpc_id              = aws_vpc.prod.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.node_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = { Name = "prod-${each.value}" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.prod.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "prod-s3" }
}
