data "aws_ec2_transit_gateway_route_table" "spoke" {
  provider = aws.network
  filter {
    name   = "transit-gateway-id"
    values = [var.transit_gateway_id]
  }
  filter {
    name   = "tag:Name"
    values = ["lz-spoke-egress"]
  }
}

data "aws_ec2_transit_gateway_route_table" "inspection" {
  provider = aws.network
  filter {
    name   = "transit-gateway-id"
    values = [var.transit_gateway_id]
  }
  filter {
    name   = "tag:Name"
    values = ["lz-inspection-return"]
  }
}

resource "aws_ec2_transit_gateway_route_table_association" "prod" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.spoke.id
  depends_on                     = [aws_ec2_transit_gateway_vpc_attachment_accepter.prod]
}

resource "aws_ec2_transit_gateway_route_table_propagation" "prod" {
  provider                       = aws.network
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.prod.id
  transit_gateway_route_table_id = data.aws_ec2_transit_gateway_route_table.inspection.id
  depends_on                     = [aws_ec2_transit_gateway_vpc_attachment_accepter.prod]
}
