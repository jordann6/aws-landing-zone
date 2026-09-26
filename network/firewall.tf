# AWS Network Firewall doing the egress inspection. An ALLOWLIST rule group means
# only the listed domains are reachable; everything else is denied by default.
# That default-deny is what enforces the pull-through cache later: a node cannot
# reach Docker Hub, only the private registry over its endpoint.

resource "aws_networkfirewall_rule_group" "allow_domains" {
  #checkov:skip=CKV_AWS_345:Demo uses the AWS-owned key; CMK for firewall encryption is the production upgrade.
  name     = "egress-allowlist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["TLS_SNI", "HTTP_HOST"]
        targets              = var.allowed_egress_domains
      }
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "hub" {
  #checkov:skip=CKV_AWS_346:Demo uses the AWS-owned key; a CMK for firewall encryption is the production upgrade.
  #checkov:skip=CKV_AWS_345:Demo uses the AWS-owned key for the policy; CMK is the production upgrade.
  name = "inspection-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.allow_domains.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "hub" {
  #checkov:skip=CKV_AWS_345:Demo uses the AWS-owned key; CMK is the production upgrade.
  #checkov:skip=CKV_AWS_344:Deletion protection is deliberately off; the deploy/demo/destroy posture requires teardown.
  name                = "inspection-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.hub.arn
  vpc_id              = aws_vpc.hub.id

  subnet_mapping {
    subnet_id = aws_subnet.this["firewall"].id
  }
}

# Firewall telemetry to CloudWatch: flow logs (every connection) and alert logs
# (what the stateful rules dropped or matched).
resource "aws_cloudwatch_log_group" "fw_flow" {
  #checkov:skip=CKV_AWS_338:14-day retention for a demo; a year is a production setting.
  #checkov:skip=CKV_AWS_158:CloudWatch CMK encryption is the production upgrade; demo uses the default key.
  name              = "/network-firewall/flow"
  retention_in_days = var.flow_log_retention_days
}

resource "aws_cloudwatch_log_group" "fw_alert" {
  #checkov:skip=CKV_AWS_338:14-day retention for a demo; a year is a production setting.
  #checkov:skip=CKV_AWS_158:CloudWatch CMK encryption is the production upgrade; demo uses the default key.
  name              = "/network-firewall/alert"
  retention_in_days = var.flow_log_retention_days
}

resource "aws_networkfirewall_logging_configuration" "hub" {
  firewall_arn = aws_networkfirewall_firewall.hub.arn

  logging_configuration {
    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.fw_flow.name
      }
    }
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.fw_alert.name
      }
    }
  }
}

# The firewall's per-AZ endpoint id, pulled out of sync_states for the routes.
locals {
  fw_endpoint_id = one([
    for ss in tolist(aws_networkfirewall_firewall.hub.firewall_status[0].sync_states) :
    ss.attachment[0].endpoint_id
  ])
}
