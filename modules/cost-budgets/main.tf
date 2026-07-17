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

data "aws_partition" "current" {
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

  budget_actions_create = (
    local.create &&
    var.budget_actions_enabled &&
    length(var.budget_action_iam_target_role_names) > 0
  )

  partition = local.create ? data.aws_partition.current[0].partition : "aws"
  account_id = (
    local.create
    ? data.aws_caller_identity.current[0].account_id
    : "000000000000"
  )

  budget_action_target_role_arns = [
    for role_name in var.budget_action_iam_target_role_names :
    "arn:${local.partition}:iam::${local.account_id}:role/${role_name}"
  ]
}

resource "aws_sns_topic" "cost_alerts" {
  count = local.create ? 1 : 0

  name = local.topic_name
  # Use AWS-managed SNS key (alias/aws/sns) — satisfies CKV_AWS_50 without CMK cost.
  kms_master_key_id = "alias/aws/sns"

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

data "aws_iam_policy_document" "budget_actions_assume" {
  count = local.budget_actions_create ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:budgets::${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "budget_actions" {
  count = local.budget_actions_create ? 1 : 0

  name               = "${var.name_prefix}-budget-actions"
  assume_role_policy = data.aws_iam_policy_document.budget_actions_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "deny_karpenter_scale_out" {
  count = local.budget_actions_create ? 1 : 0

  statement {
    sid    = "DenyKarpenterScaleOut"
    effect = "Deny"
    actions = [
      "ec2:CreateFleet",
      "ec2:RunInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deny_karpenter_scale_out" {
  count = local.budget_actions_create ? 1 : 0

  name        = "${var.name_prefix}-deny-karpenter-scale-out"
  description = "Budget Action policy: deny Karpenter EC2 scale-out when approved after a budget breach."
  policy      = data.aws_iam_policy_document.deny_karpenter_scale_out[0].json
  tags        = var.tags
}

data "aws_iam_policy_document" "budget_actions_permissions" {
  count = local.budget_actions_create ? 1 : 0

  statement {
    sid = "ManageOnlyBudgetDenyPolicyOnTargetRoles"
    actions = [
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = local.budget_action_target_role_arns

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [aws_iam_policy.deny_karpenter_scale_out[0].arn]
    }
  }

  statement {
    sid       = "ListTargetRolePolicies"
    actions   = ["iam:ListAttachedRolePolicies"]
    resources = local.budget_action_target_role_arns
  }
}

resource "aws_iam_role_policy" "budget_actions" {
  count = local.budget_actions_create ? 1 : 0

  name   = "${var.name_prefix}-budget-actions"
  role   = aws_iam_role.budget_actions[0].id
  policy = data.aws_iam_policy_document.budget_actions_permissions[0].json
}

resource "aws_budgets_budget_action" "monthly_deny_scale_out" {
  count = local.budget_actions_create ? 1 : 0

  budget_name        = aws_budgets_budget.monthly[0].name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "MANUAL"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_actions[0].arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = var.budget_action_monthly_threshold_percentage
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.deny_karpenter_scale_out[0].arn
      roles      = var.budget_action_iam_target_role_names
    }
  }

  subscriber {
    address           = var.alert_email
    subscription_type = "EMAIL"
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.budget_actions,
    aws_sns_topic_policy.cost_alerts,
  ]
}

resource "aws_budgets_budget_action" "daily_deny_scale_out" {
  count = local.budget_actions_create && var.create_daily_budget ? 1 : 0

  budget_name        = aws_budgets_budget.daily[0].name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "MANUAL"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_actions[0].arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = var.budget_action_daily_threshold_percentage
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.deny_karpenter_scale_out[0].arn
      roles      = var.budget_action_iam_target_role_names
    }
  }

  subscriber {
    address           = var.alert_email
    subscription_type = "EMAIL"
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy.budget_actions,
    aws_sns_topic_policy.cost_alerts,
  ]
}
