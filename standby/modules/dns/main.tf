# The zone does not need to be a registered domain. Failover routing is
# demonstrated with route53 test-dns-answer, which evaluates health checks
# exactly like a live resolver would. Delegating this subdomain from a real
# zone makes it publicly resolvable with no other changes.
resource "aws_route53_zone" "this" {
  #checkov:skip=CKV2_AWS_38:The demo zone is never delegated; routing is proven with test-dns-answer.
  #checkov:skip=CKV2_AWS_39:Query logging needs a log group in us-east-1 with a resource policy; not worth it for a destroyed demo zone.
  name          = var.domain_name
  comment       = "Multi-region failover demo zone"
  force_destroy = true
}

resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_fqdn
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  request_interval  = 10
  failure_threshold = 2

  tags = {
    Name = "primary-api-health"
  }
}

resource "aws_route53_record" "primary" {
  zone_id        = aws_route53_zone.this.zone_id
  name           = "app.${var.domain_name}"
  type           = "CNAME"
  ttl            = 30
  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id
  records         = [var.primary_fqdn]
}

resource "aws_route53_record" "secondary" {
  zone_id        = aws_route53_zone.this.zone_id
  name           = "app.${var.domain_name}"
  type           = "CNAME"
  ttl            = 30
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  records = [var.secondary_fqdn]
}
