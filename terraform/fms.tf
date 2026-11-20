# Firewall Manager (Step 5). The security account becomes the FMS administrator,
# the same account that administers GuardDuty, Security Hub and Config. The
# association is free.
#
# The policy below is written but off. Firewall Manager bills $100 per policy per
# region per month, and partial months are not documented as prorated, so a
# one-hour demo would likely cost the full $100. The zone's one WAF (the ingress
# web ACL in network/ingress.tf) is managed directly instead. Turning this on in a
# real org replaces that per-account web ACL with one org-wide rule: every ALB in
# Workloads and Infrastructure gets the AWS baseline rule groups, and any ALB
# without them shows as non-compliant. Firewall Manager needs AWS Config in every
# account it covers, which config-org.tf provides.

variable "fms_enabled" {
  description = "Create the Firewall Manager WAF policy (~$100/month per policy per region). The admin association is always on and free."
  type        = bool
  default     = false
}

resource "aws_fms_admin_account" "security" {
  account_id = local.security_account_id
}

resource "aws_fms_policy" "alb_baseline_waf" {
  count    = var.fms_enabled ? 1 : 0
  provider = aws.security

  name                               = "alb-baseline-waf"
  description                        = "Every ALB in Workloads and Infrastructure gets the AWS baseline WAF rule groups"
  resource_type                      = "AWS::ElasticLoadBalancingV2::LoadBalancer"
  exclude_resource_tags              = false
  remediation_enabled                = false # audit first: report non-compliant ALBs, change nothing
  delete_all_policy_resources        = true
  delete_unused_fm_managed_resources = true

  include_map {
    orgunit = [
      local.acct.workloads_ou_id,
      local.acct.infrastructure_ou_id,
    ]
  }

  security_service_policy_data {
    type = "WAFV2"
    managed_service_data = jsonencode({
      type = "WAFV2"
      preProcessRuleGroups = [
        for name in ["AWSManagedRulesAmazonIpReputationList", "AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"] : {
          ruleGroupArn               = null
          overrideAction             = { type = "NONE" }
          managedRuleGroupIdentifier = { vendorName = "AWS", managedRuleGroupName = name, version = null }
          ruleGroupType              = "ManagedRuleGroup"
          excludeRules               = []
        }
      ]
      postProcessRuleGroups             = []
      defaultAction                     = { type = "ALLOW" }
      overrideCustomerWebACLAssociation = false
      loggingConfiguration              = null
    })
  }

  depends_on = [aws_fms_admin_account.security]
}
