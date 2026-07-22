output "vault_name" {
  value       = aws_backup_vault.mandate20.name
  description = "Mandate 20 AWS Backup vault name"
}

output "vault_arn" {
  value       = aws_backup_vault.mandate20.arn
  description = "Mandate 20 AWS Backup vault ARN"
}

output "backup_service_role_arn" {
  value       = aws_iam_role.backup_service.arn
  description = "IAM role assumed by AWS Backup for plans/selections"
}

output "kms_key_arn" {
  value       = aws_kms_key.backup.arn
  description = "KMS key encrypting vault recovery points"
}

output "daily_plan_id" {
  value       = aws_backup_plan.daily.id
  description = "Daily managed-store backup plan ID"
}

output "ebs_hourly_plan_id" {
  value       = aws_backup_plan.ebs_hourly.id
  description = "Hourly EBS backup plan ID"
}

output "ebs_hourly_selection_id" {
  value       = aws_backup_selection.ebs_hourly.id
  description = "Hourly EBS backup selection ID"
}

# Change trail: @hungxqt - 2026-07-22 - Mandate 20 backup module outputs.
