output "endpoint" {
  value       = aws_db_instance.this.address
  description = "Private RDS PostgreSQL endpoint."
}

output "port" {
  value       = aws_db_instance.this.port
  description = "PostgreSQL port."
}

output "master_user_secret_arn" {
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
  description = "RDS-managed master credential secret ARN."
  sensitive   = true
}

output "connection_secret_arn" {
  value       = aws_secretsmanager_secret.connection.arn
  description = "ASM secret containing non-sensitive connection metadata."
}

output "kms_key_arn" {
  value       = aws_kms_key.rds.arn
  description = "KMS key used by RDS and its connection metadata secret."
}

output "security_group_id" {
  value       = aws_security_group.rds.id
  description = "RDS client security group."
}

output "destructive_ddl_alarm_name" {
  value       = try(aws_cloudwatch_metric_alarm.destructive_ddl[0].alarm_name, null)
  description = "CloudWatch alarm that detects logged DROP TABLE and TRUNCATE TABLE statements."
}
