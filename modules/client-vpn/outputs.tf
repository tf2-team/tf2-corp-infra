output "enabled" {
  description = "Whether this module created Client VPN resources"
  value       = var.enabled
}

output "client_vpn_endpoint_id" {
  description = "Client VPN endpoint ID (null when disabled)"
  value       = var.enabled ? aws_ec2_client_vpn_endpoint.this[0].id : null
}

output "client_vpn_endpoint_arn" {
  description = "Client VPN endpoint ARN (null when disabled)"
  value       = var.enabled ? aws_ec2_client_vpn_endpoint.this[0].arn : null
}

output "client_vpn_endpoint_dns_name" {
  description = "Client VPN endpoint DNS name for client configuration (null when disabled)"
  value       = var.enabled ? aws_ec2_client_vpn_endpoint.this[0].dns_name : null
}

output "client_vpn_security_group_id" {
  description = "Security group ID attached to Client VPN ENIs (null when disabled)"
  value       = var.enabled ? aws_security_group.client_vpn[0].id : null
}

output "client_cidr_block" {
  description = "CIDR assigned to VPN clients (empty when disabled)"
  value       = var.enabled ? var.client_cidr_block : ""
}

output "authorized_destination_cidrs" {
  description = "Destination CIDRs authorized for VPN clients"
  value       = var.enabled ? [var.vpc_cidr_block] : []
}

output "associated_subnet_ids" {
  description = "Subnet IDs associated with the Client VPN endpoint"
  value       = var.enabled ? var.subnet_ids : []
}

output "export_client_config_command" {
  description = "CMD hint to export OpenVPN client configuration (null when disabled)"
  value = var.enabled ? (
    "aws ec2 export-client-vpn-client-configuration --client-vpn-endpoint-id ${aws_ec2_client_vpn_endpoint.this[0].id} --output text > client-vpn.ovpn"
  ) : null
}

output "operator_note" {
  description = "Short operator reminder for enablement and admin path access"
  value       = <<-EOT
    Client VPN (private admin path to internal storefront ALB):
    1) Generate CA + server + client certs; import server + client CA into ACM (same region as VPC).
    2) Set client_vpn_enabled=true, certificate ARNs, optional alb_security_group_ids (ALB SG for TCP 80).
    3) terraform apply → export .ovpn, embed client cert/key, connect.
    4) curl http://<INTERNAL_ALB_DNS>/grafana/  (expect not CF 403).
    5) curl https://<CloudFront_alias>/grafana/ still 403 when edge blocking is on.
    6) See docs/client-vpn.md. Disable with client_vpn_enabled=false to stop association charges.
  EOT
}
