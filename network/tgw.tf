# Transit Gateway owned by the network account. Workload spokes (dev/test/prod/
# sandbox) attach to it and reach the internet only through the inspection VPC.
# Shared to the org over RAM so spoke accounts can attach without owning it.

resource "aws_ec2_transit_gateway" "hub" {
  description = "Landing zone hub transit gateway"
  # Attachments are accepted explicitly, not automatically, so a spoke cannot
  # join the hub without a deliberate act.
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = { Name = "lz-hub-tgw" }
}

# appliance_mode keeps a flow pinned to one AZ's firewall endpoint in both
# directions, which is what makes stateful inspection work across the TGW.
resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = aws_ec2_transit_gateway.hub.id
  vpc_id             = aws_vpc.hub.id
  subnet_ids         = [aws_subnet.this["tgw"].id]

  appliance_mode_support                          = "enable"
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "hub-inspection-attachment" }
}

resource "aws_ram_resource_share" "tgw" {
  name                      = "lz-hub-tgw"
  allow_external_principals = false
  tags                      = { Name = "lz-hub-tgw" }
}

resource "aws_ram_resource_association" "tgw" {
  resource_arn       = aws_ec2_transit_gateway.hub.arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}

resource "aws_ram_principal_association" "org" {
  count = var.org_arn != "" ? 1 : 0

  principal          = var.org_arn
  resource_share_arn = aws_ram_resource_share.tgw.arn
}
