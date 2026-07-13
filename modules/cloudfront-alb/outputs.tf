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
