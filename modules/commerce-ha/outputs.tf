output "valkey_primary_endpoint" {
  value       = aws_elasticache_replication_group.cart.primary_endpoint_address
  description = "ElastiCache primary endpoint behind the stable private DNS record"
}

output "valkey_application_address" {
  value       = "${local.valkey_dns_name}:6379"
  description = "Stable private address consumed by cart"
}

output "valkey_auth_secret_arn" {
  value       = aws_secretsmanager_secret.valkey_auth.arn
  description = "Secrets Manager ARN containing the managed Valkey password"
}

output "commerce_kms_key_arn" {
  value       = aws_kms_key.commerce.arn
  description = "Customer-managed KMS key used by Valkey, DynamoDB, and its authentication secret"
}

output "checkout_outbox_table_name" {
  value       = aws_dynamodb_table.checkout_outbox.name
  description = "DynamoDB durable checkout outbox table"
}

output "checkout_outbox_role_arn" {
  value       = aws_iam_role.checkout_outbox.arn
  description = "IRSA role for the checkout ServiceAccount"
}

output "accounting_outbox_reconciler_role_arn" {
  value       = aws_iam_role.accounting_outbox_reconciler.arn
  description = "IRSA role allowing accounting to query and requeue stale published checkout events"
}
