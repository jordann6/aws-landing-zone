# The routing that makes inspection mandatory. Each subnet tier gets its own
# route table so traffic is forced through the firewall in both directions:
#
#   egress:  spoke -> TGW -> tgw subnet -> firewall -> NAT -> IGW
#   return:  IGW -> NAT -> public subnet -> firewall -> TGW -> spoke
#
# There is no route that reaches the internet without passing the firewall endpoint.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "hub-public" }
}

resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "hub-firewall" }
}

resource "aws_route_table" "tgw" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "hub-tgw" }
}

resource "aws_route_table" "endpoints" {
  vpc_id = aws_vpc.hub.id
  tags   = { Name = "hub-endpoints" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.this["public"].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.this["firewall"].id
  route_table_id = aws_route_table.firewall.id
}

resource "aws_route_table_association" "tgw" {
  subnet_id      = aws_subnet.this["tgw"].id
  route_table_id = aws_route_table.tgw.id
}

resource "aws_route_table_association" "endpoints" {
  subnet_id      = aws_subnet.this["endpoints"].id
  route_table_id = aws_route_table.endpoints.id
}

# Public subnet: NAT reaches the internet via IGW; traffic back to spokes is sent
# to the firewall first, so the return path is inspected too.
resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.hub.id
}

resource "aws_route" "public_to_spokes" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "10.0.0.0/8"
  vpc_endpoint_id        = local.fw_endpoint_id
}

# Firewall subnet: inspected egress goes to NAT; inspected return goes to the TGW.
resource "aws_route" "firewall_default" {
  route_table_id         = aws_route_table.firewall.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.hub.id
}

resource "aws_route" "firewall_to_spokes" {
  route_table_id         = aws_route_table.firewall.id
  destination_cidr_block = "10.0.0.0/8"
  transit_gateway_id     = aws_ec2_transit_gateway.hub.id
}

# TGW subnet: everything arriving from the spokes is sent to the firewall.
resource "aws_route" "tgw_default" {
  route_table_id         = aws_route_table.tgw.id
  destination_cidr_block = "0.0.0.0/0"
  vpc_endpoint_id        = local.fw_endpoint_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}
