# Cost governance at the management account, which sees consolidated spend for
# the whole org. Two layers: a fixed monthly budget that alerts on a known
# ceiling, and anomaly detection that alerts on an unexpected shape regardless of
# the ceiling. The budget catches "we are trending over"; anomaly detection
# catches "something started billing that never billed before", which for a
# deploy/demo/destroy portfolio is usually a forgotten teardown.

resource "aws_budgets_budget" "monthly" {
  name         = "org-monthly-cost"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Warn on the forecast before the actual, so the alert arrives with time to act.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}

# AWS permits a single SERVICE-dimension anomaly monitor per account. Gated so the
# zone can deploy where one already exists (set enable_cost_anomaly_monitor=false).
resource "aws_ce_anomaly_monitor" "services" {
  count             = var.enable_cost_anomaly_monitor ? 1 : 0
  name              = "org-service-anomalies"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "services" {
  count     = var.enable_cost_anomaly_monitor ? 1 : 0
  name      = "org-service-anomaly-alerts"
  frequency = "DAILY"

  monitor_arn_list = aws_ce_anomaly_monitor.services[*].arn

  subscriber {
    type    = "EMAIL"
    address = var.budget_notification_email
  }

  # Only alert once the absolute dollar impact clears the threshold, so the
  # sub-dollar noise of a demo does not train the alert to be ignored.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [var.cost_anomaly_threshold]
    }
  }
}
