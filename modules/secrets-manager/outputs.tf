output "secret_arns" {
  description = "Map of secret key → ARN (metadata only; no secret values)"
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}

output "secret_names" {
  description = "Map of secret key → full ASM name"
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.name }
}

output "secret_arns_list" {
  description = "List of secret ARNs for IAM resource policies"
  value       = [for s in aws_secretsmanager_secret.this : s.arn]
}

output "name_prefix" {
  description = "ASM path prefix used for this environment"
  value       = var.name_prefix
}
