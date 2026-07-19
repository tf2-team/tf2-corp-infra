output "audit_bucket_name" {
  value = aws_s3_bucket.audit_events.id
}

output "firehose_stream_arn" {
  value = aws_kinesis_firehose_delivery_stream.audit_events.arn
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.audit.arn
}

output "lambda_function_name" {
  value = aws_lambda_function.k8s_audit_fine_filter.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.k8s_audit_fine_filter.arn
}
