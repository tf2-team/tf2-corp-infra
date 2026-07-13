output "distribution_id" {
  description = "CloudFront distribution ID (null when disabled)"
  value       = var.enabled ? aws_cloudfront_distribution.storefront[0].id : null
}

output "domain_name" {
  description = "CloudFront domain name (e.g. d111111abcdef8.cloudfront.net); point DNS CNAME/ALIAS here"
  value       = var.enabled ? aws_cloudfront_distribution.storefront[0].domain_name : null
}

output "hosted_zone_id" {
  description = "CloudFront Route53 hosted zone ID for alias records (null when disabled)"
  value       = var.enabled ? aws_cloudfront_distribution.storefront[0].hosted_zone_id : null
}

output "arn" {
  description = "CloudFront distribution ARN (null when disabled)"
  value       = var.enabled ? aws_cloudfront_distribution.storefront[0].arn : null
}

output "status" {
  description = "Distribution status (Deployed when ready; null when disabled)"
  value       = var.enabled ? aws_cloudfront_distribution.storefront[0].status : null
}

output "aliases" {
  description = "Configured alternate domain names (empty when disabled)"
  value       = var.enabled ? var.aliases : []
}

output "enabled" {
  description = "Whether this module created a distribution"
  value       = var.enabled
}

output "vpc_origin_id" {
  description = "CloudFront VPC origin ID (null when disabled)"
  value       = var.enabled ? aws_cloudfront_vpc_origin.storefront[0].id : null
}

output "vpc_origin_arn" {
  description = "CloudFront VPC origin ARN (null when disabled)"
  value       = var.enabled ? aws_cloudfront_vpc_origin.storefront[0].arn : null
}

output "block_sensitive_paths" {
  description = "Whether the CloudFront path-block function is attached"
  value       = var.enabled && var.block_sensitive_paths
}

output "blocked_prefixes" {
  description = "Prefixes blocked at CloudFront when path blocking is enabled (empty when off)"
  value       = var.enabled && var.block_sensitive_paths ? var.blocked_prefixes : []
}

output "block_function_arn" {
  description = "CloudFront Function ARN for path blocking (null when not created)"
  value       = var.enabled && var.block_sensitive_paths ? aws_cloudfront_function.block_sensitive_paths[0].arn : null
}
