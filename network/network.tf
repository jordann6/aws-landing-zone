# Centralized egress/inspection VPC in the network account. Everything the
# workload spokes send to the internet is forced through here: spoke -> TGW ->
# this VPC -> Network Firewall -> NAT -> IGW, with the return path inspected too.
#
# Demo scope: the data path runs in a single AZ to keep the firewall-endpoint
# routing tractable and cheap. Production spans every AZ with a firewall endpoint
# and NAT per AZ; the routing pattern below is identical per AZ.

locals {
  subnets = {
    public    = cidrsubnet(var.hub_cidr, 8, 10) # 10.0.10.0/24 - NAT + IGW
    firewall  = cidrsubnet(var.hub_cidr, 8, 20) # 10.0.20.0/24 - firewall endpoint
    tgw       = cidrsubnet(var.hub_cidr, 8, 30) # 10.0.30.0/24 - TGW attachment ENIs
    endpoints = cidrsubnet(var.hub_cidr, 8, 40) # 10.0.40.0/24 - interface endpoints
  }
}

resource "aws_vpc" "hub" {
  cidr_block           = var.hub_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "inspection-hub" }
}

# Lock the default SG to no rules (a default open SG is a silent lateral path).
resource "aws_default_security_group" "hub" {
  vpc_id = aws_vpc.hub.id
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.hub.id
  cidr_block        = each.value
  availability_zone = var.az
  tags              = { Name = "hub-${each.key}" }
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "inspection-hub" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "hub-nat" }
}

resource "aws_nat_gateway" "hub" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.this["public"].id
  tags          = { Name = "hub-nat" }

  depends_on = [aws_internet_gateway.hub]
}
