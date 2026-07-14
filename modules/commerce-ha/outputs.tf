output "valkey_primary_endpoint" {
  value       = aws_elasticache_replication_group.cart.primary_endpoint_address
  description = "ElastiCache primary endpoint behind the stable private DNS record"
}

output "valkey_application_address" {
  value       = "${local.valkey_dns_name}:6379"
  description = "Stable private address consumed by cart"
}

output "checkout_outbox_table_name" {
  value       = aws_dynamodb_table.checkout_outbox.name
  description = "DynamoDB durable checkout outbox table"
}

output "checkout_outbox_role_arn" {
  value       = aws_iam_role.checkout_outbox.arn
  description = "IRSA role for the checkout ServiceAccount"
}
