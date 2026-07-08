output "state_bucket_name" {
  value       = aws_s3_bucket.state_bucket.id
  description = "Tên của S3 bucket lưu trữ Terraform state"
}

output "state_bucket_region" {
  value       = var.aws_region
  description = "Region của S3 bucket"
}

output "state_kms_key_arn" {
  value       = aws_kms_key.state_key.arn
  description = "ARN của KMS key mã hóa S3 state bucket"
}

output "backend_config_snippet" {
  value       = <<EOF
bucket       = "${aws_s3_bucket.state_bucket.id}"
region       = "${var.aws_region}"
encrypt      = true
use_lockfile = true
EOF
  description = "Đoạn cấu hình mẫu cho backend.hcl"
}
