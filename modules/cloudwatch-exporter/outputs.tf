output "role_arn" {
  value       = aws_iam_role.this.arn
  description = "IRSA role ARN for the YACE CloudWatch exporter"
}

# Change trail: AIO4 - 2026-07-26 - Export the YACE CloudWatch metric-read role ARN.
