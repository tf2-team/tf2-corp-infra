output "role_arn" {
  value       = aws_iam_role.this.arn
  description = "IAM role ARN for GitHub Actions (set as AWS_ROLE_ARN on the matching GitHub Environment)"
}

output "role_name" {
  value       = aws_iam_role.this.name
  description = "IAM role name"
}

output "allowed_subjects" {
  value       = local.allowed_subjects
  description = "OIDC sub claims allowed to assume this role"
}
