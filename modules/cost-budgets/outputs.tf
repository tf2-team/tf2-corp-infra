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

output "operator_note" {
  description = "Post-apply steps for cost budgets"
  value = var.enabled ? join("\n", [
    "1) Confirm SNS email-json subscription for ${var.alert_email} (inbox / spam).",
    "2) Billing → Budgets: monthly ${var.monthly_limit_usd} USD (≈ $300/week × 3) + daily ${var.daily_limit_usd} USD.",
    "3) AWS has no WEEKLY time_unit; monthly $900 maps the capstone weekly ceiling.",
    "4) Budgets only alert — they do not stop spend; cut idle VPN/load-gen/Spot when warned.",
  ]) : "cost budgets disabled"
}
