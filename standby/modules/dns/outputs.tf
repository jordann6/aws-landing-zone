output "zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "primary_health_check_id" {
  value = aws_route53_health_check.primary.id
}

output "app_fqdn" {
  value = "app.${var.domain_name}"
}
