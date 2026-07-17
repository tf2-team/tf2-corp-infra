output "bucket_name" {
  value = aws_s3_bucket.models.id
}

output "bucket_arn" {
  value = aws_s3_bucket.models.arn
}

output "model_prefix" {
  description = "Backward-compatible product-reviews model prefix"
  value       = try(var.consumers["product-reviews"].model_prefix, null)
}

output "service_account_role_arn" {
  description = "Backward-compatible product-reviews IRSA role ARN"
  value       = try(aws_iam_role.model_read["product-reviews"].arn, null)
}

output "consumer_model_prefixes" {
  description = "S3 model prefix keyed by consumer"
  value       = { for name, consumer in var.consumers : name => consumer.model_prefix }
}

output "consumer_role_arns" {
  description = "IRSA role ARN keyed by model consumer"
  value       = { for name, role in aws_iam_role.model_read : name => role.arn }
}

output "consumer_access_contracts" {
  description = "Reviewable least-privilege contract keyed by model consumer"
  value       = local.consumer_access_contracts
}

output "s3_vpc_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
