output "enabled" {
  description = "Whether cost anomaly resources were created"
  value       = var.enabled
}

output "monitor_arn" {
  description = "Cost Anomaly monitor ARN (null when disabled)"
  value       = var.enabled ? aws_ce_anomaly_monitor.service[0].arn : null
}

output "monitor_name" {
  description = "Cost Anomaly monitor name (null when disabled)"
  value       = var.enabled ? aws_ce_anomaly_monitor.service[0].name : null
}

output "subscription_arn" {
  description = "Cost Anomaly subscription ARN (null when disabled)"
  value       = var.enabled ? aws_ce_anomaly_subscription.this[0].arn : null
}

output "subscription_name" {
  description = "Cost Anomaly subscription name (null when disabled)"
  value       = var.enabled ? aws_ce_anomaly_subscription.this[0].name : null
}

output "operator_note" {
  description = "Post-apply steps for Cost Anomaly Detection"
  value = var.enabled ? join("\n", [
    "1) Billing → Cost Anomaly Detection: monitor ${local.monitor_name}, subscription ${local.subscription_name}.",
    "2) Confirm email for ${var.alert_email} if AWS sends a confirmation (check spam).",
    "3) Threshold: impact >= $${var.impact_absolute_usd} AND >= ${var.impact_percentage}% (frequency ${var.frequency}).",
    "4) CAD is not a hard stop — investigate spikes (NAT, EC2, data transfer) and cut idle spend.",
    "5) Account-level: do not also wire this module from development on the same account.",
  ]) : "cost anomaly disabled"
}
