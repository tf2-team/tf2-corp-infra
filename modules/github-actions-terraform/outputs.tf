output "role_arn" {
  value       = aws_iam_role.this.arn
  description = "IAM role ARN for GitHub Actions Terraform (set as repository secret)"
}

output "role_name" {
  value       = aws_iam_role.this.name
  description = "IAM role name"
}

output "allowed_subjects" {
  value       = local.allowed_subjects
  description = "OIDC sub claims allowed to assume this role"
}

output "permission_level" {
  value       = var.permission_level
  description = "plan or apply"
}

output "state_key_prefixes" {
  value       = var.state_key_prefixes
  description = "State key prefixes this role may access"
}

output "iam_name_prefixes" {
  value       = var.iam_name_prefixes
  description = "IAM name prefixes this apply role may manage (empty for plan roles)"
}
