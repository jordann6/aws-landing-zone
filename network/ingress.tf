# Ingress DMZ: the internet-facing edge of the zone, in the network account
# beside the egress path. An application load balancer in two public ingress
# subnets, fronted by an AWS WAF web ACL, under a jordandesigns.io subdomain.
#
# Egress from the spokes is inspected by Network Firewall (firewall.tf). Ingress
# is inspected at layer 7 by WAF instead: managed rule groups for common
# exploits and known-bad inputs, Amazon's IP reputation list, and a per-IP rate
# limit. The listener answers with a fixed response, so there is no backend to
# pay for and nothing behind the edge to expose; the point is the edge itself.
#
# Part of the hourly network root, so it exists only while the stack is up and
# goes away with destroy.yml. Cost while up: ALB ~$0.0225/hr plus LCUs, WAF
# $5/month per web ACL and $1/month per rule billed by the hour, $0.60 per
# million requests. A few cents per demo session.

variable "ingress_enabled" {
  description = "Build the ingress DMZ (ALB + WAF + DNS). Off leaves the hub egress-only."
  type        = bool
  default     = true
}

variable "ingress_azs" {
  description = "Two AZs for the ingress subnets; an ALB needs at least two"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "ingress_zone_name" {
  description = "Public hosted zone (management account) the ingress name lives under"
  type        = string
  default     = "jordandesigns.io"
}

variable "ingress_hostname" {
  description = "DNS name of the ingress endpoint"
  type        = string
  default     = "lz-ingress.jordandesigns.io"
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes from one IP before the rate rule blocks it"
  type        = number
  default     = 100
}

locals {
  ingress = var.ingress_enabled ? 1 : 0
  ingress_subnets = var.ingress_enabled ? {
    for i, az in var.ingress_azs : az => cidrsubnet(var.hub_cidr, 8, 50 + i) # 10.0.50.0/24, 10.0.51.0/24
  } : {}
  waf_log_bucket_arn = "arn:aws:s3:::aws-waf-logs-${data.terraform_remote_state.accounts.outputs.log_archive_account_id}"
}

# The jordandesigns.io zone is in the management account, where the site lives.
# This alias uses the management CI identity directly (no assume), whose Route 53
# permissions are limited to the ingress hostname's records (bootstrap/roles.tf).
provider "aws" {
  alias  = "management"
  region = var.region

  default_tags {
    tags = {
      Project     = "aws-landing-zone"
      Environment = "network"
      Owner       = var.owner
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

# --- DMZ subnets --------------------------------------------------------------
# Public subnets for the load balancer only. They share the hub's public route
# table: 0.0.0.0/0 to the internet gateway, 10.0.0.0/8 through the firewall, so
# anything the edge ever forwards inward is still inspected on the way.
resource "aws_subnet" "ingress" {
  for_each = local.ingress_subnets

  vpc_id            = aws_vpc.hub.id
  cidr_block        = each.value
  availability_zone = each.key
  tags              = { Name = "hub-ingress-${each.key}" }
}

resource "aws_route_table_association" "ingress" {
  for_each = aws_subnet.ingress

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "ingress_alb" {
  #checkov:skip=CKV_AWS_260:Port 80 exists only to redirect to 443; the listener never serves content on it.
  count = local.ingress

  name        = "hub-ingress-alb"
  description = "Internet-facing ALB: HTTPS in, HTTP only to redirect"
  vpc_id      = aws_vpc.hub.id

  ingress {
    description = "HTTP, redirected to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # No egress rule: the listener answers with a fixed response and has no
  # targets, so the load balancer never opens a connection inward.
  tags = { Name = "hub-ingress-alb" }
}

# --- Load balancer --------------------------------------------------------------
#trivy:ignore:AVD-AWS-0053:Internet-facing by design; this is the DMZ edge, fronted by the WAF web ACL below and answering only with a fixed response.
resource "aws_lb" "ingress" {
  #checkov:skip=CKV_AWS_150:Deletion protection off by design; the hourly stack is destroyed after every demo.
  #checkov:skip=CKV_AWS_91:Request logging is the WAF log in log-archive, which records every request with its rule verdict.
  #checkov:skip=CKV2_AWS_20:HTTP listener exists only to redirect to HTTPS (aws_lb_listener.ingress_http).
  #checkov:skip=CKV2_AWS_76:The attached web ACL runs AWSManagedRulesKnownBadInputsRuleSet (Log4JRCE); CKV_AWS_192 passes on it, but the graph check does not follow the count-indexed association.
  count = local.ingress

  name                       = "hub-ingress"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.ingress_alb[0].id]
  subnets                    = [for s in aws_subnet.ingress : s.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = false
}

data "aws_route53_zone" "ingress" {
  count    = local.ingress
  provider = aws.management

  name         = var.ingress_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "ingress" {
  count = local.ingress

  domain_name       = var.ingress_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "ingress_validation" {
  for_each = var.ingress_enabled ? {
    for o in aws_acm_certificate.ingress[0].domain_validation_options : o.domain_name => o
  } : {}
  provider = aws.management

  zone_id         = data.aws_route53_zone.ingress[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "ingress" {
  count = local.ingress

  certificate_arn         = aws_acm_certificate.ingress[0].arn
  validation_record_fqdns = [for r in aws_route53_record.ingress_validation : r.fqdn]
}

resource "aws_lb_listener" "ingress_https" {
  count = local.ingress

  load_balancer_arn = aws_lb.ingress[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.ingress[0].certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "aws-landing-zone ingress: request passed WAF\n"
      status_code  = "200"
    }
  }
}

resource "aws_lb_listener" "ingress_http" {
  #checkov:skip=CKV_AWS_2:Redirect-only listener; every request is answered with a 301 to HTTPS.
  #checkov:skip=CKV_AWS_103:Redirect-only listener; TLS policy applies to the HTTPS listener.
  count = local.ingress

  load_balancer_arn = aws_lb.ingress[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "ingress" {
  count    = local.ingress
  provider = aws.management

  zone_id = data.aws_route53_zone.ingress[0].zone_id
  name    = var.ingress_hostname
  type    = "A"

  alias {
    name                   = aws_lb.ingress[0].dns_name
    zone_id                = aws_lb.ingress[0].zone_id
    evaluate_target_health = false
  }
}

# --- WAF ------------------------------------------------------------------------
# Rule order: drop known-bad sources first (IP reputation), then the per-IP rate
# limit, then content inspection. All three managed groups are in WAF's free
# baseline tier (no per-group subscription charge).
resource "aws_wafv2_web_acl" "ingress" {
  count = local.ingress

  name        = "hub-ingress"
  description = "Edge protection for the landing zone ingress ALB"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 0
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "hub-ingress"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "ingress" {
  count = local.ingress

  resource_arn = aws_lb.ingress[0].arn
  web_acl_arn  = aws_wafv2_web_acl.ingress[0].arn
}

# Every request and its verdict, delivered across accounts to the persistent
# aws-waf-logs-* bucket in log-archive (terraform/waf-logs.tf).
resource "aws_wafv2_web_acl_logging_configuration" "ingress" {
  count = local.ingress

  resource_arn            = aws_wafv2_web_acl.ingress[0].arn
  log_destination_configs = [local.waf_log_bucket_arn]
}

output "ingress_url" {
  description = "HTTPS endpoint of the WAF-protected ingress ALB"
  value       = var.ingress_enabled ? "https://${var.ingress_hostname}" : null
}

output "ingress_web_acl_arn" {
  value = try(aws_wafv2_web_acl.ingress[0].arn, null)
}
