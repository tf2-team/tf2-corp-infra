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

# ──────────────────────────────────────────────
# MANDATE 10: Cosign KMS signing key
# ──────────────────────────────────────────────

output "cosign_kms_key_arn" {
  value       = aws_kms_key.cosign.arn
  description = "KMS key ARN used by platform CI to sign image digests with Cosign (awskms:///alias/<name>)"
}

output "cosign_kms_key_alias" {
  value       = aws_kms_alias.cosign.name
  description = "Matches the COSIGN_KMS_KEY fallback already hardcoded in tf2-corp-platform build-and-push.yml (awskms:///alias/tf2-cosign-signing-key); no GitHub var override needed unless this alias changes"
}

# ──────────────────────────────────────────────
# GitHub Actions Terraform plan/apply roles (infra repo)
# Set these as repository secrets on the infra GitHub repo
# ──────────────────────────────────────────────

output "github_actions_terraform_role_arns" {
  value = {
    for key, mod in module.github_actions_terraform : key => mod.role_arn
  }
  description = "Map of terraform CI role key → IAM role ARN"
}

output "github_actions_terraform_role_names" {
  value = {
    for key, mod in module.github_actions_terraform : key => mod.role_name
  }
  description = "Map of terraform CI role key → IAM role name"
}

output "github_actions_terraform_allowed_subjects" {
  value = {
    for key, mod in module.github_actions_terraform : key => mod.allowed_subjects
  }
  description = "OIDC subjects allowed to assume each Terraform plan/apply role"
}

output "DEV_AWS_PLAN_ROLE_ARN" {
  value       = module.github_actions_terraform["development-plan"].role_arn
  description = "GitHub Actions repository secret DEV_AWS_PLAN_ROLE_ARN"
}

output "DEV_AWS_APPLY_ROLE_ARN" {
  value       = module.github_actions_terraform["development-apply"].role_arn
  description = "GitHub Actions repository secret DEV_AWS_APPLY_ROLE_ARN"
}

output "PROD_AWS_PLAN_ROLE_ARN" {
  value       = module.github_actions_terraform["production-plan"].role_arn
  description = "GitHub Actions repository secret PROD_AWS_PLAN_ROLE_ARN"
}

output "PROD_AWS_APPLY_ROLE_ARN" {
  value       = module.github_actions_terraform["production-apply"].role_arn
  description = "GitHub Actions repository secret PROD_AWS_APPLY_ROLE_ARN"
}

output "github_actions_terraform_github_secrets" {
  value = {
    DEV_AWS_PLAN_ROLE_ARN   = module.github_actions_terraform["development-plan"].role_arn
    DEV_AWS_APPLY_ROLE_ARN  = module.github_actions_terraform["development-apply"].role_arn
    DEV_TF_BACKEND_BUCKET   = aws_s3_bucket.state_bucket.id
    DEV_TF_BACKEND_REGION   = var.aws_region
    DEV_AWS_REGION          = var.aws_region
    PROD_AWS_PLAN_ROLE_ARN  = module.github_actions_terraform["production-plan"].role_arn
    PROD_AWS_APPLY_ROLE_ARN = module.github_actions_terraform["production-apply"].role_arn
    PROD_TF_BACKEND_BUCKET  = aws_s3_bucket.state_bucket.id
    PROD_TF_BACKEND_REGION  = var.aws_region
    PROD_AWS_REGION         = var.aws_region
  }
  description = "Convenience map of all ten infra-repo GitHub Actions secrets (names → values)"
}
