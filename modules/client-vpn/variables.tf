variable "enabled" {
  type        = bool
  description = "When false, module creates no resources"
  default     = false
  nullable    = false
}

variable "name" {
  type        = string
  description = "Name prefix for Client VPN resources (logs, security group tags)"
  default     = "client-vpn"
  nullable    = false
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the Client VPN endpoint"
  default     = ""
  nullable    = false
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR authorized for VPN clients (authorization rule destination)"
  default     = ""
  nullable    = false
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs to associate (start with one AZ for cost control)"
  default     = []
  nullable    = false
}

variable "client_cidr_block" {
  type        = string
  description = <<-EOT
    IPv4 CIDR assigned to VPN clients. Must not overlap the VPC CIDR.
    Recommended: /22 (provides enough client IPs; AWS reserves some addresses).
  EOT
  default     = "10.100.0.0/22"
  nullable    = false

  validation {
    condition     = can(cidrhost(var.client_cidr_block, 0))
    error_message = "client_cidr_block must be a valid IPv4 CIDR."
  }
}

variable "server_certificate_arn" {
  type        = string
  description = <<-EOT
    ACM certificate ARN for the Client VPN server (same region as the VPC).
    The imported leaf must have a non-empty DomainName (FQDN CN/SAN such as
    server.clientvpn.techx.local). Bare CN=server or a CA-only cert fails with
    CreateClientVpnEndpoint "Certificate ... does not have a domain".
  EOT
  default     = ""
  nullable    = false
}

variable "client_root_certificate_chain_arn" {
  type        = string
  description = "ACM certificate ARN of the client CA (root/intermediate) for mutual TLS auth"
  default     = ""
  nullable    = false
}

variable "split_tunnel" {
  type        = bool
  description = "When true, only VPC-destined traffic uses the VPN (recommended)"
  default     = true
  nullable    = false
}

variable "transport_protocol" {
  type        = string
  description = "Client VPN transport protocol"
  default     = "udp"
  nullable    = false

  validation {
    condition     = contains(["udp", "tcp"], var.transport_protocol)
    error_message = "transport_protocol must be udp or tcp."
  }
}

variable "vpn_port" {
  type        = number
  description = "Client VPN port (443 recommended)"
  default     = 443
  nullable    = false
}

variable "session_timeout_hours" {
  type        = number
  description = "Maximum Client VPN session duration in hours (8–24 typically)"
  default     = 24
  nullable    = false
}

variable "connection_log_enabled" {
  type        = bool
  description = "Enable Client VPN connection logging to CloudWatch"
  default     = true
  nullable    = false
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch log group retention for connection logs"
  default     = 14
  nullable    = false
}

variable "dns_servers" {
  type        = list(string)
  description = <<-EOT
    DNS servers pushed to clients. Empty = do not set dns_servers on the endpoint
    (clients use their local DNS). Set to [cidrhost(vpc_cidr, 2)] for AmazonProvidedDNS
    when you need private Route53 / VPC name resolution over VPN.
  EOT
  default     = []
  nullable    = false
}

variable "ingress_cidr_blocks" {
  type        = list(string)
  description = "CIDRs allowed to initiate Client VPN connections (UDP/TCP vpn_port)"
  default     = ["0.0.0.0/0"]
  nullable    = false
}

variable "alb_security_group_ids" {
  type        = list(string)
  description = <<-EOT
    Optional security group IDs of the internal storefront ALB.
    When non-empty and enabled, adds ingress TCP 80 from this module's Client VPN
    association security group (SG-to-SG) so VPN clients can reach the existing
    internal ALB without taking SG ownership via Ingress annotations (avoids
    fighting CloudFront VPC-origin SG automation).
  EOT
  default     = []
  nullable    = false
}

variable "alb_ingress_port" {
  type        = number
  description = "Port opened on alb_security_group_ids for VPN clients (HTTP 80)"
  default     = 80
  nullable    = false
}

variable "eks_cluster_security_group_ids" {
  type        = list(string)
  description = <<-EOT
    Optional EKS cluster security group ID(s). When non-empty and enabled, adds
    ingress TCP 443 from this module's Client VPN association security group
    (SG-to-SG). Client CIDR alone is insufficient for private EKS API ENIs.
    Pass module.eks.cluster_security_group_id from the environment stack.
  EOT
  default     = []
  nullable    = false
}

variable "eks_api_ingress_port" {
  type        = number
  description = "Port opened on eks_cluster_security_group_ids for VPN clients (Kubernetes API 443)"
  default     = 443
  nullable    = false
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to created resources"
  default     = {}
  nullable    = false
}
