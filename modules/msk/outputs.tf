output "msk_cluster_arn" {
  value       = aws_msk_cluster.this.arn
  description = "Amazon Resource Name (ARN) of the MSK cluster"
}

output "bootstrap_brokers_tls" {
  value       = aws_msk_cluster.this.bootstrap_brokers_tls
  description = "Comma-separated list of MSK broker TLS connection strings"
}

output "msk_bootstrap_secret_arn" {
  value       = aws_secretsmanager_secret.msk_bootstrap.arn
  description = "Secrets Manager Secret ARN containing the MSK bootstrap brokers TLS string"
}

output "msk_kms_key_arn" {
  value       = aws_kms_key.msk.arn
  description = "ARN of the KMS key used to encrypt MSK cluster data and its secret"
}
