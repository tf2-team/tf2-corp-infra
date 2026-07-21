output "policy_arn" {
  value       = aws_iam_policy.deny_destructive_backup.arn
  description = "ARN of the deny-destructive-backup managed policy"
}

output "policy_name" {
  value       = aws_iam_policy.deny_destructive_backup.name
  description = "Name of the deny-destructive-backup managed policy"
}

output "attached_role_names" {
  value       = var.attach_role_names
  description = "Roles that receive the policy attachment in this apply"
}

output "attached_group_names" {
  value       = var.attach_group_names
  description = "Groups that receive the policy attachment in this apply"
}

# Change trail: @hungxqt - 2026-07-21 - Export attached group names for Mandate 20 criterion B.
