output "sns_topic_arn" {
  description = "SNS topic ARN for runtime security alerts."
  value       = var.enabled ? aws_sns_topic.runtime_security[0].arn : null
}

output "audit_classifier_function_name" {
  description = "Lambda function name for EKS audit deny classification."
  value       = var.enabled ? aws_lambda_function.audit_classifier[0].function_name : null
}

output "audit_log_subscription_filter_name" {
  description = "CloudWatch Logs subscription filter for EKS audit denies."
  value       = var.enabled ? aws_cloudwatch_log_subscription_filter.eks_audit_denies[0].name : null
}

output "classifier_error_alarm_name" {
  description = "CloudWatch alarm name for audit classifier errors."
  value       = var.enabled ? aws_cloudwatch_metric_alarm.audit_classifier_errors[0].alarm_name : null
}

output "classifier_deadman_alarm_name" {
  description = "CloudWatch alarm name for audit classifier missing processed-event metric."
  value       = var.enabled && var.enable_classifier_deadman_alarm ? aws_cloudwatch_metric_alarm.audit_classifier_no_processed_events[0].alarm_name : null
}

output "guardduty_event_rule_name" {
  description = "EventBridge rule for GuardDuty runtime findings."
  value       = var.enabled && var.enable_guardduty_eventbridge ? aws_cloudwatch_event_rule.guardduty_runtime[0].name : null
}

output "node_role_event_rule_name" {
  description = "EventBridge rule for selected worker-node role CloudTrail events."
  value       = var.enabled && var.enable_node_role_anomaly_events && length(var.node_role_arns) > 0 ? aws_cloudwatch_event_rule.node_role_anomaly[0].name : null
}

output "operator_note" {
  description = "Post-apply notes for runtime security alerting."
  value = var.enabled ? join("\n", compact([
    "Runtime security SNS topic: ${aws_sns_topic.runtime_security[0].arn}",
    var.alert_email != "" ? "Confirm the SNS email-json subscription for ${var.alert_email}." : "No email subscription configured; wire SNS to the approved on-call channel.",
    "EKS audit deny classifier watches ${var.audit_log_group_name} and sends sanitized Mandate 05 admission-deny alerts.",
    "GuardDuty EventBridge routing enabled: ${var.enable_guardduty_eventbridge}. This module does not enable GuardDuty Runtime Monitoring.",
    "Node-role anomaly routing enabled: ${var.enable_node_role_anomaly_events}. Enable only after baseline approval.",
  ])) : "runtime security alerting disabled"
}
