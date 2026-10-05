output "transit_gateway_id" {
  value = aws_ec2_transit_gateway.hub.id
}

output "transit_gateway_arn" {
  value = aws_ec2_transit_gateway.hub.arn
}

output "hub_vpc_id" {
  value = aws_vpc.hub.id
}

output "firewall_arn" {
  value = aws_networkfirewall_firewall.hub.arn
}

output "ram_share_arn" {
  value = aws_ram_resource_share.tgw.arn
}
output "spoke_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.spoke.id
}

output "inspection_route_table_id" {
  value = aws_ec2_transit_gateway_route_table.inspection.id
}
