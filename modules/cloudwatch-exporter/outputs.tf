output "role_arn" {
  value       = aws_iam_role.this.arn
  description = "IAM role ARN for the eks.amazonaws.com/role-arn ServiceAccount annotation"
}

output "role_name" {
  value       = aws_iam_role.this.name
  description = "IAM role name"
}

# Change trail: @hungxqt - 2026-07-26 - IRSA role for YACE CloudWatch read-only metrics access.
