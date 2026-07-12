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

# ──────────────────────────────────────────────
# GitHub Actions OIDC + ECR push roles
# ──────────────────────────────────────────────

output "github_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github.arn
  description = "Account-level GitHub Actions OIDC provider ARN"
}

output "github_actions_ecr_role_arns" {
  value = {
    for key, mod in module.github_actions_ecr : key => mod.role_arn
  }
  description = "Map of environment key → IAM role ARN for platform GitHub Actions ECR push"
}

output "github_actions_ecr_role_names" {
  value = {
    for key, mod in module.github_actions_ecr : key => mod.role_name
  }
  description = "Map of environment key → IAM role name for platform GitHub Actions ECR push"
}

output "github_actions_ecr_production_role_arn" {
  value       = module.github_actions_ecr["production"].role_arn
  description = "Set as GitHub Environment variable AWS_ROLE_ARN on platform environment 'production'"
}

output "github_actions_ecr_development_role_arn" {
  value       = module.github_actions_ecr["development"].role_arn
  description = "Set as GitHub Environment variable AWS_ROLE_ARN on platform environment 'development'"
}

output "github_actions_allowed_subjects" {
  value = {
    for key, mod in module.github_actions_ecr : key => mod.allowed_subjects
  }
  description = "OIDC subjects allowed to assume each ECR push role"
}
