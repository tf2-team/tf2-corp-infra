output "enabled" {
  description = "Whether cost budget resources were created"
  value       = var.enabled
}

output "sns_topic_arn" {
  description = "SNS topic ARN for cost alerts (null when disabled)"
  value       = var.enabled ? aws_sns_topic.cost_alerts[0].arn : null
}

output "sns_topic_name" {
  description = "SNS topic name (null when disabled)"
  value       = var.enabled ? aws_sns_topic.cost_alerts[0].name : null
}

output "sns_subscription_arn" {
  description = "SNS email-json subscription ARN (PendingConfirmation until email Confirm)"
  value       = var.enabled ? aws_sns_topic_subscription.cost_email_json[0].arn : null
}

output "monthly_budget_name" {
  description = "Monthly budget name (null when disabled)"
  value       = var.enabled ? aws_budgets_budget.monthly[0].name : null
}

output "daily_budget_name" {
  description = "Daily budget name (null when disabled or daily off)"
  value       = var.enabled && var.create_daily_budget ? aws_budgets_budget.daily[0].name : null
}

output "budget_actions_execution_role_arn" {
  description = "IAM role ARN assumed by AWS Budgets to attach/detach the deny scale-out policy"
  value       = local.budget_actions_create ? aws_iam_role.budget_actions[0].arn : null
}

output "budget_actions_deny_policy_arn" {
  description = "IAM policy ARN attached by Budget Actions to deny Karpenter scale-out"
  value       = local.budget_actions_create ? aws_iam_policy.deny_karpenter_scale_out[0].arn : null
}

output "monthly_budget_action_arn" {
  description = "Monthly manual Budget Action ARN (null when disabled)"
  value       = local.budget_actions_create ? aws_budgets_budget_action.monthly_deny_scale_out[0].arn : null
}

output "daily_budget_action_arn" {
  description = "Daily manual Budget Action ARN (null when disabled)"
  value       = local.budget_actions_create && var.create_daily_budget ? aws_budgets_budget_action.daily_deny_scale_out[0].arn : null
}

output "operator_note" {
  description = "Post-apply steps for cost budgets"
  value = var.enabled ? join("\n", [
    "1) Confirm SNS email-json subscription for ${var.alert_email} (inbox / spam).",
    "2) Billing → Budgets: monthly ${var.monthly_limit_usd} USD (≈ $300/week × 3) + daily ${var.daily_limit_usd} USD.",
    "3) AWS has no WEEKLY time_unit; monthly $900 maps the capstone weekly ceiling.",
    "4) Budget Actions enabled=${var.budget_actions_enabled}; approval model is MANUAL when enabled.",
    "5) Manual action target roles: ${length(var.budget_action_iam_target_role_names) > 0 ? join(", ", var.budget_action_iam_target_role_names) : "(none)"}",
    "6) Actions attach the deny scale-out policy only after operator approval; no prod auto-stop is configured.",
  ]) : "cost budgets disabled"
}
