output "enabled" {
  description = "Whether this module created private DNS resources"
  value       = var.enabled
}

output "zone_id" {
  description = "Private hosted zone ID (null when disabled)"
  value       = var.enabled ? aws_route53_zone.private[0].zone_id : null
}

output "zone_name" {
  description = "Private hosted zone / operator hostname (empty when disabled)"
  value       = var.enabled ? var.zone_name : ""
}

output "zone_arn" {
  description = "Private hosted zone ARN (null when disabled)"
  value       = var.enabled ? aws_route53_zone.private[0].arn : null
}

output "name_servers" {
  description = "Name servers for the private zone (informational; VPC association is what matters)"
  value       = var.enabled ? aws_route53_zone.private[0].name_servers : []
}

output "hostname" {
  description = "Operator internal hostname (zone apex)"
  value       = var.enabled ? var.zone_name : ""
}

output "base_url" {
  description = "HTTP or HTTPS base URL for the internal entrypoint (empty when disabled)"
  value       = var.enabled ? "${local.url_scheme}://${var.zone_name}" : ""
}

output "service_urls" {
  description = "Map of service short name → full URL (hostname + path)"
  value = var.enabled ? {
    for name, path in var.service_paths :
    name => "${local.url_scheme}://${var.zone_name}${path}"
  } : {}
}

output "alb_dns_name" {
  description = "Resolved storefront ALB DNS name used as alias target (null when disabled)"
  value       = var.enabled && var.alb_arn != "" ? data.aws_lb.storefront[0].dns_name : null
}

output "acm_certificate_arn" {
  description = "Operator-supplied ACM certificate ARN for internal ALB HTTPS (empty when unset)"
  value       = var.enabled ? var.acm_certificate_arn : ""
}

output "https_enabled" {
  description = "True when an ACM certificate ARN was supplied (HTTPS intended on the ALB)"
  value       = local.use_https
}

output "operator_note" {
  description = "Operator reminder for private DNS + optional TLS + Client VPN access"
  value       = <<-EOT
    Private DNS (${var.zone_name}):
    1) Client VPN must push AmazonProvidedDNS (module default) so laptops use VPC DNS.
    2) While connected: nslookup ${var.zone_name}
    3) Path-based service URLs (frontend-proxy):
         ${local.url_scheme}://${var.zone_name}/grafana/
         ${local.url_scheme}://${var.zone_name}/jaeger/
    4) HTTPS: issue ACM cert for ${var.zone_name} in us-east-1 (DNS validation in public DNS),
       set private_dns_acm_certificate_arn in tfvars, and the same ARN on chart
       publicAlb.certificateArn. Keep HTTP:80 for CloudFront; do NOT enable ALB ssl-redirect.
    5) Public storefront remains https://shop… (CloudFront); not this hostname.
    6) Off VPN: private zone is not public; ${var.zone_name} does not resolve on the internet.
    7) After ALB recreate: update cloudfront_origin_alb_arn (same ARN used here) and apply.
  EOT
}
