output "lambda_function_name" {
  description = "Audit alert router Lambda function name."
  value       = var.enabled ? aws_lambda_function.router[0].function_name : null
}

output "lambda_function_arn" {
  description = "Audit alert router Lambda function ARN."
  value       = var.enabled ? aws_lambda_function.router[0].arn : null
}

output "cloudtrail_event_rule_arn" {
  description = "EventBridge rule ARN for dangerous CloudTrail API events."
  value       = var.enabled ? aws_cloudwatch_event_rule.cloudtrail_dangerous_api[0].arn : null
}

output "sqs_queue_url" {
  description = "SQS queue URL that Task 11.3 can use as the alert routing destination."
  value       = var.enabled ? aws_sqs_queue.routing[0].url : null
}

output "sqs_queue_arn" {
  description = "SQS queue ARN for audit alert routing."
  value       = var.enabled ? aws_sqs_queue.routing[0].arn : null
}

output "sqs_dlq_url" {
  description = "Dead-letter queue URL for failed Discord deliveries."
  value       = var.enabled ? aws_sqs_queue.dlq[0].url : null
}

output "kubernetes_audit_subscription_name" {
  description = "CloudWatch Logs subscription filter name for Kubernetes audit logs."
  value       = var.enabled && var.kubernetes_audit_enabled ? aws_cloudwatch_log_subscription_filter.kubernetes_audit[0].name : null
}

output "operator_note" {
  description = "Post-apply steps and acceptance test guidance."
  value = var.enabled ? join("\n", [
    "Audit detection routing enabled.",
    "Contract path: Task 11.3 alert payload -> SQS ${aws_sqs_queue.routing[0].url} -> ${aws_lambda_function.router[0].function_name} -> Discord.",
    "CloudTrail/EventBridge fallback path: AWS API Call via CloudTrail -> ${aws_cloudwatch_event_rule.cloudtrail_dangerous_api[0].name} -> SQS ${aws_sqs_queue.routing[0].name} -> ${aws_lambda_function.router[0].function_name} -> Discord.",
    "Discord webhook value must be stored in Secrets Manager secret ${var.discord_webhook_secret_name}, JSON key ${var.discord_webhook_secret_json_key}; never commit or paste the webhook URL.",
    "Kubernetes audit routing is ${var.kubernetes_audit_enabled ? "enabled" : "disabled"} in Terraform. Enable EKS audit logs and set kubernetes_audit_enabled=true to route K8s audit events.",
    "Safe mentor demo: create then immediately delete a test IAM access key; target time-to-detect <= 120 seconds.",
  ]) : "audit detection routing disabled"
}
