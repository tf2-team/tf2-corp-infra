# ──────────────────────────────────────────────
# AWS Cost Anomaly Detection (Cost Explorer)
#
# Detects unusual spend vs learned baseline (per SERVICE by default).
# Complements AWS Budgets (ceiling) — CAD catches sudden spikes.
# Account-level API (global CE); wire from production only when one AWS account.
#
# After apply: confirm the email subscription if AWS sends a confirmation.
# ──────────────────────────────────────────────

locals {
  create = var.enabled

  monitor_name      = "${var.name_prefix}-service-anomaly-monitor"
  subscription_name = "${var.name_prefix}-service-anomaly-alerts"
}

resource "aws_ce_anomaly_monitor" "service" {
  count = local.create ? 1 : 0

  name              = local.monitor_name
  monitor_type      = var.monitor_type
  monitor_dimension = var.monitor_type == "DIMENSIONAL" ? var.monitor_dimension : null
}

resource "aws_ce_anomaly_subscription" "this" {
  count = local.create ? 1 : 0

  name      = local.subscription_name
  frequency = var.frequency

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service[0].arn,
  ]

  # Both absolute USD and % impact must match (AND) — reduces noise.
  threshold_expression {
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = [var.impact_absolute_usd]
      }
    }
    and {
      dimension {
        key           = "ANOMALY_TOTAL_IMPACT_PERCENTAGE"
        match_options = ["GREATER_THAN_OR_EQUAL"]
        values        = [var.impact_percentage]
      }
    }
  }

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }
}
