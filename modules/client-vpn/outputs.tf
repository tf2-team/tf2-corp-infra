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
    Client VPN (internal ALB admin paths + EKS private API):
    Prerequisites setup (docs/client-vpn.md):
    1) Generate CA + server + per-user client certs (outside git).
    2) ACM Import (us-east-1), NOT Request public cert (both need --private-key):
         - server.crt+key (+ca chain) → client_vpn_server_certificate_arn
         - ca.crt+ca.key              → client_vpn_client_ca_arn  (two different ARNs)
    3) Recommended: client_vpn_alb_security_group_ids from storefront ALB SGs (TCP 80 from VPN ENI SG).
    4) EKS cluster SG TCP 443 from Client VPN association SG is wired automatically
         (eks_cluster_security_group_ids ← module.eks.cluster_security_group_id; SG-to-SG).
    5) client_vpn_enabled=true → terraform apply → wait association available.
    6) Local connect (docs/client-vpn.md "Client setup and connect"):
         export .ovpn → append client1 cert/key/ca → AWS VPN Client Connect.
    7) curl http://<INTERNAL_ALB_DNS>/grafana/ (not CF 403); CloudFront alias still 403 when blocking on.
    8) kubectl get ns works on VPN (private API) and off VPN (public EKS endpoint, if enabled).
    9) Disconnect when done; disable with client_vpn_enabled=false to stop association charges.
  EOT
}
