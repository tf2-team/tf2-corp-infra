output "parser_lambda_function_name" {
  description = "Lambda function name that receives raw CloudTrail and EKS audit candidates."
  value       = var.enabled ? aws_lambda_function.parser[0].function_name : null
}

output "parser_lambda_function_arn" {
  description = "Lambda function ARN that Task 11.3 CI/CD updates with the real parser package."
  value       = var.enabled ? aws_lambda_function.parser[0].arn : null
}

output "cloudtrail_event_rule_name" {
  description = "EventBridge rule name for CloudTrail candidate events."
  value       = var.enabled ? aws_cloudwatch_event_rule.cloudtrail_candidates[0].name : null
}

output "cloudtrail_event_rule_arn" {
  description = "EventBridge rule ARN for CloudTrail candidate events."
  value       = var.enabled ? aws_cloudwatch_event_rule.cloudtrail_candidates[0].arn : null
}

output "eks_audit_log_group_name" {
  description = "EKS control-plane log group watched by the CloudWatch Logs subscription filter."
  value       = var.enabled ? local.audit_log_group : null
}

output "eks_audit_subscription_filter_name" {
  description = "CloudWatch Logs subscription filter name for EKS audit candidates."
  value       = var.enabled ? aws_cloudwatch_log_subscription_filter.eks_audit_candidates[0].name : null
}

output "dlq_arn" {
  description = "SQS DLQ ARN for failed audit detection pipeline events."
  value       = var.enabled ? aws_sqs_queue.audit_detection_dlq[0].arn : null
}

output "dlq_url" {
  description = "SQS DLQ URL for failed audit detection pipeline events."
  value       = var.enabled ? aws_sqs_queue.audit_detection_dlq[0].url : null
}

output "alert_ready_queue_url" {
  description = "SQS queue URL used by the parser to hand alert-ready payloads to the Discord router."
  value       = var.enabled && var.enable_discord_router ? aws_sqs_queue.alert_ready[0].url : null
}

output "alert_ready_queue_arn" {
  description = "SQS queue ARN used by the parser to hand alert-ready payloads to the Discord router."
  value       = var.enabled && var.enable_discord_router ? aws_sqs_queue.alert_ready[0].arn : null
}

output "alert_ready_dlq_url" {
  description = "SQS DLQ URL for alert-ready messages that the Discord router cannot deliver."
  value       = var.enabled && var.enable_discord_router ? aws_sqs_queue.alert_ready_dlq[0].url : null
}

output "router_lambda_function_name" {
  description = "Lambda function name for the Mandate 11.4 Discord router."
  value       = var.enabled && var.enable_discord_router ? aws_lambda_function.router[0].function_name : null
}

output "router_lambda_function_arn" {
  description = "Lambda function ARN for the Mandate 11.4 Discord router."
  value       = var.enabled && var.enable_discord_router ? aws_lambda_function.router[0].arn : null
}

output "discord_webhook_secret_arn" {
  description = "Secrets Manager ARN that stores the Mandate 11 Discord webhook URL."
  value       = var.enabled && var.enable_discord_router ? local.discord_webhook_secret_arn : null
}

output "ttd_dashboard_name" {
  description = "CloudWatch dashboard name for Mandate 11.5 TTD evidence."
  value       = var.enabled && var.enable_discord_router && var.enable_ttd_dashboard ? aws_cloudwatch_dashboard.ttd[0].dashboard_name : null
}

output "lambda_error_alarm_name" {
  description = "CloudWatch alarm name for parser Lambda errors."
  value       = var.enabled && var.enable_alarms ? aws_cloudwatch_metric_alarm.lambda_errors[0].alarm_name : null
}

output "lambda_throttle_alarm_name" {
  description = "CloudWatch alarm name for parser Lambda throttles."
  value       = var.enabled && var.enable_alarms ? aws_cloudwatch_metric_alarm.lambda_throttles[0].alarm_name : null
}

output "eventbridge_failed_invocation_alarm_name" {
  description = "CloudWatch alarm name for EventBridge failed Lambda invocations."
  value       = var.enabled && var.enable_alarms ? aws_cloudwatch_metric_alarm.eventbridge_failed_invocations[0].alarm_name : null
}

output "dlq_visible_messages_alarm_name" {
  description = "CloudWatch alarm name for visible messages in the audit detection DLQ."
  value       = var.enabled && var.enable_alarms ? aws_cloudwatch_metric_alarm.dlq_visible_messages[0].alarm_name : null
}

output "router_error_alarm_name" {
  description = "CloudWatch alarm name for router Lambda errors."
  value       = var.enabled && var.enable_discord_router && var.enable_alarms ? aws_cloudwatch_metric_alarm.router_errors[0].alarm_name : null
}

output "router_throttle_alarm_name" {
  description = "CloudWatch alarm name for router Lambda throttles."
  value       = var.enabled && var.enable_discord_router && var.enable_alarms ? aws_cloudwatch_metric_alarm.router_throttles[0].alarm_name : null
}

output "alert_ready_dlq_visible_messages_alarm_name" {
  description = "CloudWatch alarm name for visible messages in the alert-ready router DLQ."
  value       = var.enabled && var.enable_discord_router && var.enable_alarms ? aws_cloudwatch_metric_alarm.alert_ready_dlq_visible_messages[0].alarm_name : null
}

output "end_to_end_ttd_alarm_name" {
  description = "CloudWatch alarm name for Mandate 11.5 end-to-end TTD threshold breach."
  value       = var.enabled && var.enable_discord_router && var.enable_alarms ? aws_cloudwatch_metric_alarm.end_to_end_ttd_high[0].alarm_name : null
}

output "operator_note" {
  description = "Post-apply notes for Task 11.2/11.3 handoff."
  value = var.enabled ? join("\n", [
    "Mandate 11.2 audit detection pipeline is enabled.",
    "Task 11.3 parser Lambda: ${aws_lambda_function.parser[0].function_name}",
    "CloudTrail candidates route: EventBridge rule ${aws_cloudwatch_event_rule.cloudtrail_candidates[0].name} -> Lambda raw event.",
    "EKS audit candidates route: log group ${local.audit_log_group} subscription ${aws_cloudwatch_log_subscription_filter.eks_audit_candidates[0].name} -> Lambda raw awslogs.data.",
    "DLQ: ${aws_sqs_queue.audit_detection_dlq[0].arn}",
    var.enable_discord_router ? "Task 11.4 router: parser -> SQS ${aws_sqs_queue.alert_ready[0].name} -> Lambda ${aws_lambda_function.router[0].function_name} -> Discord." : "Task 11.4 router is disabled; parser emits alert_ready evidence only.",
    var.enable_discord_router ? "Task 11.5 TTD evidence: CloudWatch dashboard ${local.ttd_dashboard_name}; final evidence status is alert_sent." : "Task 11.5 final Discord TTD is unavailable until router is enabled.",
    var.enable_discord_router ? "Discord webhook secret ARN: ${local.discord_webhook_secret_arn}. Store only the secret value out of Terraform state." : "No Discord secret created.",
    "Before final handoff, capture one raw CloudTrail sample, one raw EKS audit sample, and five alert_sent evidence records from Lambda logs.",
  ]) : "Mandate 11.2 audit detection pipeline disabled"
}
