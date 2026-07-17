output "notification_configuration_arn" {
  description = "AWS User Notifications configuration ARN"
  value       = var.enabled ? aws_notifications_notification_configuration.this[0].arn : null
}

output "email_contact_arn" {
  description = "AWS User Notifications email contact ARN"
  value       = var.enabled ? aws_notificationscontacts_email_contact.this[0].arn : null
}

output "event_rule_arn" {
  description = "AWS User Notifications event rule ARN for Cost Anomaly events"
  value       = var.enabled ? aws_notifications_event_rule.cost_anomaly[0].arn : null
}

output "operator_note" {
  description = "Post-apply steps for anomaly routing"
  value = var.enabled ? join("\n", [
    "1) Confirm the AWS User Notifications email contact for ${var.notification_email}.",
    "2) Event source aws.ce / Cost Anomaly Detected is routed only when impact > ${var.impact_absolute_usd} USD.",
    "3) Slack is intentionally not configured in this overlay; add AWS Chatbot later if needed.",
  ]) : "cost anomaly routing disabled"
}
