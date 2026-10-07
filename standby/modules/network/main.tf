data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:No internet or NAT path exists in this VPC, so there is no egress to log; short-lived.
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# Private subnets only. Nothing in this VPC needs internet access, so there
# is no IGW and no NAT gateway to pay for or forget during teardown.
resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${count.index}"
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.name_prefix}-db"
  }
}

resource "aws_security_group" "lambda" {
  #checkov:skip=CKV2_AWS_5:Attached to the Lambda, RDS and endpoint through module outputs.
  name        = "${var.name_prefix}-lambda"
  description = "App Lambda functions"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-lambda"
  }
}

resource "aws_security_group" "rds" {
  #checkov:skip=CKV2_AWS_5:Attached to the Lambda, RDS and endpoint through module outputs.
  name        = "${var.name_prefix}-rds"
  description = "PostgreSQL instances"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rds"
  }
}

resource "aws_security_group" "vpc_endpoint" {
  #checkov:skip=CKV2_AWS_5:Attached to the Lambda, RDS and endpoint through module outputs.
  name        = "${var.name_prefix}-vpce"
  description = "Secrets Manager interface endpoint"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-vpce"
  }
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_rds" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "PostgreSQL to RDS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.rds.id
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_vpce" {
  security_group_id            = aws_security_group.lambda.id
  description                  = "HTTPS to the Secrets Manager endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.vpc_endpoint.id
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_lambda" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from app Lambdas"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.lambda.id
}

resource "aws_vpc_security_group_ingress_rule" "vpce_from_lambda" {
  security_group_id            = aws_security_group.vpc_endpoint.id
  description                  = "HTTPS from app Lambdas"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.lambda.id
}

# Interface endpoint so the in-VPC Lambdas can fetch credentials without a
# NAT gateway. One subnet keeps it at 0.01 USD per hour per region.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private[0].id]
  security_group_ids  = [aws_security_group.vpc_endpoint.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-secretsmanager"
  }
}

# The default security group carries no rules, so nothing can use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-default-locked"
  }
}
