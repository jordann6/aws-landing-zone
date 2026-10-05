# Prod workload VPC (10.3.0.0/16). Fully private: no IGW and no NAT. All egress
# leaves through the Transit Gateway to the hub inspection VPC, so this VPC
# inherits the centralized firewall and has no independent path to the internet.
#
# Subnet plan (shared by the data tier and the EKS cluster):
#   node  10.3.0.0/20   EKS nodes (pods use node ENIs; service CIDR 10.3.32.0/19)
#   data  10.3.16.0/24  RDS, isolated
#   app   10.3.20.0/24  application tier
#   tgw   10.3.18.0/28  TGW attachment ENIs

locals {
  subnets = {
    node_a = { cidr = "10.3.0.0/21", az = var.azs[0], tier = "node" }
    node_b = { cidr = "10.3.8.0/21", az = var.azs[1], tier = "node" }
    data_a = { cidr = "10.3.16.0/24", az = var.azs[0], tier = "data" }
    data_b = { cidr = "10.3.17.0/24", az = var.azs[1], tier = "data" }
    app_a  = { cidr = "10.3.20.0/24", az = var.azs[0], tier = "app" }
    app_b  = { cidr = "10.3.21.0/24", az = var.azs[1], tier = "app" }
    tgw_a  = { cidr = "10.3.18.0/28", az = var.azs[0], tier = "tgw" }
    tgw_b  = { cidr = "10.3.18.16/28", az = var.azs[1], tier = "tgw" }
  }

  data_subnet_ids = [for k, s in local.subnets : aws_subnet.this[k].id if s.tier == "data"]
  node_subnet_ids = [for k, s in local.subnets : aws_subnet.this[k].id if s.tier == "node"]
  tgw_subnet_ids  = [for k, s in local.subnets : aws_subnet.this[k].id if s.tier == "tgw"]
}

resource "aws_vpc" "prod" {
  cidr_block           = var.prod_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "prod-workload" }
}

resource "aws_default_security_group" "prod" {
  vpc_id = aws_vpc.prod.id
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.prod.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags = {
    Name = "prod-${each.key}"
    Tier = each.value.tier
  }
}

# Cross-account TGW attachment: requested from prod, accepted in the network
# account (auto-accept is off on the TGW by design).
resource "aws_ec2_transit_gateway_vpc_attachment" "prod" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.prod.id
  subnet_ids         = local.tgw_subnet_ids

  # Shared TGW routing flags are managed by the network-account accepter below.
  # The requester provider cannot read or manage those flags across RAM sharing.

  tags = { Name = "prod-attachment" }
}

resource "aws_ec2_transit_gateway_vpc_attachment_accepter" "prod" {
  provider                                        = aws.network
  transit_gateway_attachment_id                   = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false
  tags                                            = { Name = "prod-attachment" }
}

# Private route table: everything not local goes to the TGW (and on to the hub
# firewall). No 0.0.0.0/0 to an IGW exists anywhere in this VPC.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.prod.id
  tags   = { Name = "prod-private" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment_accepter.prod]
}

resource "aws_route_table_association" "private" {
  for_each = { for k, s in local.subnets : k => s if s.tier != "tgw" }

  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.private.id
}
