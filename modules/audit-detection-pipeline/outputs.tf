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

output "operator_note" {
  description = "Post-apply notes for Task 11.2/11.3 handoff."
  value = var.enabled ? join("\n", [
    "Mandate 11.2 audit detection pipeline is enabled.",
    "Task 11.3 parser Lambda: ${aws_lambda_function.parser[0].function_name}",
    "CloudTrail candidates route: EventBridge rule ${aws_cloudwatch_event_rule.cloudtrail_candidates[0].name} -> Lambda raw event.",
    "EKS audit candidates route: log group ${local.audit_log_group} subscription ${aws_cloudwatch_log_subscription_filter.eks_audit_candidates[0].name} -> Lambda raw awslogs.data.",
    "DLQ: ${aws_sqs_queue.audit_detection_dlq[0].arn}",
    "Before final handoff, capture one raw CloudTrail sample and one raw EKS audit sample from Lambda logs for 11.3 verification.",
  ]) : "Mandate 11.2 audit detection pipeline disabled"
}

