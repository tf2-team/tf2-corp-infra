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
  value = var.enabled ? (
    var.use_https_urls ? "https://${var.zone_name}" : "http://${var.zone_name}"
  ) : ""
}

output "service_urls" {
  description = "Map of service short name → full URL (hostname + path)"
  value = var.enabled ? {
    for name, path in var.service_paths :
    name => "${var.use_https_urls ? "https" : "http"}://${var.zone_name}${path}"
  } : {}
}

output "alb_dns_name" {
  description = "Resolved storefront ALB DNS name used as alias target (null when disabled)"
  value       = var.enabled && var.alb_arn != "" ? data.aws_lb.storefront[0].dns_name : null
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for zone_name (null when not requested)"
  value       = var.enabled && var.request_acm_certificate ? aws_acm_certificate.internal[0].arn : null
}

output "acm_certificate_status" {
  description = "ACM certificate status (null when not requested)"
  value       = var.enabled && var.request_acm_certificate ? aws_acm_certificate.internal[0].status : null
}

output "acm_validation_records" {
  description = <<-EOT
    DNS records to create in *public* DNS to validate the ACM certificate.
    Map domain → { name, type, value }. Empty when certificate not requested.
  EOT
  value = var.enabled && var.request_acm_certificate ? {
    for dvo in aws_acm_certificate.internal[0].domain_validation_options :
    dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}
}

output "operator_note" {
  description = "Operator reminder for private DNS + optional TLS + Client VPN access"
  value       = <<-EOT
    Private DNS (${var.zone_name}):
    1) Client VPN must push AmazonProvidedDNS (module default) so laptops use VPC DNS.
    2) While connected: nslookup ${var.zone_name}
    3) Path-based service URLs (frontend-proxy):
         ${var.use_https_urls ? "https" : "http"}://${var.zone_name}/grafana/
         ${var.use_https_urls ? "https" : "http"}://${var.zone_name}/jaeger/
    4) HTTPS (optional): set request_acm_certificate=true → apply → create public DNS
       validation CNAMEs from acm_validation_records → wait ISSUED → set chart
       publicAlb.certificateArn + listenPorts HTTP+HTTPS (keep HTTP:80 for CloudFront).
       Do NOT enable ALB ssl-redirect (breaks CloudFront VPC origin HTTP).
    5) Public storefront remains https://shop… (CloudFront); not this hostname.
    6) Off VPN: private zone is not public; ${var.zone_name} does not resolve on the internet.
    7) After ALB recreate: update cloudfront_origin_alb_arn (same ARN used here) and apply.
  EOT
}
