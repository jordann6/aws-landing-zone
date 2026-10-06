output "primary_api_endpoint" {
  description = "Invoke URL of the primary region API"
  value       = module.app_primary.api_endpoint
}

output "secondary_api_endpoint" {
  description = "Invoke URL of the standby region API"
  value       = module.app_secondary.api_endpoint
}

output "app_fqdn" {
  description = "Failover record name inside the demo hosted zone"
  value       = module.dns.app_fqdn
}

output "hosted_zone_id" {
  description = "Hosted zone id, needed for route53 test-dns-answer"
  value       = module.dns.zone_id
}

output "primary_health_check_id" {
  description = "Route 53 health check watching the primary /health endpoint"
  value       = module.dns.primary_health_check_id
}

output "replica_identifier" {
  description = "RDS read replica the failover Lambda promotes"
  value       = module.db_replica.identifier
}

output "failover_function_name" {
  description = "Failover manager Lambda in the standby region"
  value       = module.failover.function_name
}

output "primary_api_function_name" {
  description = "Primary app Lambda, used to simulate a regional failure"
  value       = module.app_primary.function_name
}
