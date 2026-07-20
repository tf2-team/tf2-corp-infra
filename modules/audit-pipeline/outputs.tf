output "audit_alert_queue_url" {
  value = aws_sqs_queue.audit_alert_queue.url
}

output "audit_alert_queue_arn" {
  value = aws_sqs_queue.audit_alert_queue.arn
}

output "parse_lambda_name" {
  value = aws_lambda_function.parse_lambda.function_name
}

output "alert_lambda_name" {
  value = aws_lambda_function.alert_lambda.function_name
}

output "cloudtrail_eventbridge_rule_arn" {
  value = aws_cloudwatch_event_rule.cloudtrail_high_risk.arn
}

output "kms_key_arn" {
  value = aws_kms_key.audit_pipeline.arn
}
