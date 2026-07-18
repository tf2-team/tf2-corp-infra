output "endpoint" {
  value       = aws_db_instance.this.address
  description = "Private RDS hostname for Mem0"
}

output "port" {
  value       = aws_db_instance.this.port
  description = "PostgreSQL port"
}

output "database_name" {
  value       = aws_db_instance.this.db_name
  description = "Initial Mem0 database name"
}

output "instance_arn" {
  value       = aws_db_instance.this.arn
  description = "Mem0 RDS instance ARN"
}

output "resource_id" {
  value       = aws_db_instance.this.resource_id
  description = "Immutable RDS resource ID used to scope IAM database connect permissions"
}

output "security_group_id" {
  value       = aws_security_group.this.id
  description = "Security group attached to Mem0 RDS"
}

output "master_user_secret_arn" {
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  description = "RDS-managed master credential secret ARN for migration/bootstrap only"
}

output "connection_contract" {
  value = {
    host                   = aws_db_instance.this.address
    port                   = aws_db_instance.this.port
    database_name          = aws_db_instance.this.db_name
    sslmode                = "require"
    master_user_secret_arn = aws_db_instance.this.master_user_secret[0].secret_arn
  }
  description = "Connection metadata consumed by the Mem0 chart and migration job"
}
