# ──────────────────────────────────────────────
# AWS Budgets + SNS (email-json) — TF spend ceiling
#
# AWS Budgets time_unit supports only: DAILY | MONTHLY | QUARTERLY | ANNUALLY
# (WEEKLY is invalid — provider/API reject).
#
# Capstone onboarding/BUDGET.md: ~$300/week/TF × ~3 weeks → monthly ceiling $900.
# Daily budget is early-warning (~$45 ≈ 300/7).
# SNS subscription protocol is email-json (structured payload).
# Operator must Confirm the SNS email after apply.
# Budgets are account-level alerts only — they do not hard-stop spend.
# ──────────────────────────────────────────────

data "aws_caller_identity" "current" {
  count = var.enabled ? 1 : 0
}

locals {
  create = var.enabled

  topic_name = "${var.name_prefix}-cost-alerts"

  monthly_actual_notifications = {
    for t in var.monthly_actual_thresholds : "actual-${t}" => {
      threshold         = t
      notification_type = "ACTUAL"
    }
  }

  monthly_forecasted_notifications = {
    for t in var.monthly_forecasted_thresholds : "forecasted-${t}" => {
      threshold         = t
      notification_type = "FORECASTED"
    }
  }

  monthly_notifications = merge(local.monthly_actual_notifications, local.monthly_forecasted_notifications)

  daily_notifications = {
    for t in var.daily_actual_thresholds : "actual-${t}" => {
      threshold         = t
      notification_type = "ACTUAL"
    }
  }
}

resource "aws_sns_topic" "cost_alerts" {
  count = local.create ? 1 : 0

  name = local.topic_name

  # checkov:skip=CKV_AWS_50: cost-alerts topic carries no sensitive data (email-json
  # budget notifications only). KMS adds per-API cost with no security benefit here.
  # Topic policy restricts publish to budgets.amazonaws.com with SourceAccount condition.

  tags = merge(var.tags, {
    Name = local.topic_name
  })
}

# Budgets service must be allowed to publish to the topic.
resource "aws_sns_topic_policy" "cost_alerts" {
  count = local.create ? 1 : 0

  arn = aws_sns_topic.cost_alerts[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.topic_name}-budgets-publish"
    Statement = [
      {
        Sid    = "AWSBudgetsSNSPublishingPermissions"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.cost_alerts[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current[0].account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:budgets::${data.aws_caller_identity.current[0].account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "cost_email_json" {
  count = local.create ? 1 : 0

  topic_arn = aws_sns_topic.cost_alerts[0].arn
  protocol  = "email-json"
  endpoint  = var.alert_email
}

resource "aws_budgets_budget" "monthly" {
  count = local.create ? 1 : 0

  name              = "${var.name_prefix}-monthly-${var.monthly_limit_usd}"
  budget_type       = "COST"
  limit_amount      = var.monthly_limit_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = var.time_period_start

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  dynamic "notification" {
    for_each = local.monthly_notifications
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.notification_type
      subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts[0].arn]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}

resource "aws_budgets_budget" "daily" {
  count = local.create && var.create_daily_budget ? 1 : 0

  name              = "${var.name_prefix}-daily-${var.daily_limit_usd}"
  budget_type       = "COST"
  limit_amount      = var.daily_limit_usd
  limit_unit        = "USD"
  time_unit         = "DAILY"
  time_period_start = var.time_period_start

  cost_types {
    include_credit             = false
    include_discount           = true
    include_other_subscription = true
    include_recurring          = true
    include_refund             = false
    include_subscription       = true
    include_support            = true
    include_tax                = true
    include_upfront            = true
    use_amortized              = false
    use_blended                = false
  }

  dynamic "notification" {
    for_each = local.daily_notifications
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value.notification_type
      subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts[0].arn]
    }
  }

  depends_on = [aws_sns_topic_policy.cost_alerts]
}
