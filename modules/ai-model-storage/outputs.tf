output "bucket_name" {
  value = aws_s3_bucket.models.id
}

output "bucket_arn" {
  value = aws_s3_bucket.models.arn
}

output "model_prefix" {
  value = var.model_prefix
}

output "service_account_role_arn" {
  value = aws_iam_role.model_read.arn
}

output "s3_vpc_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}
