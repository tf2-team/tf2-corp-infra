# ──────────────────────────────────────────────
# AWS Client VPN — private operator access to VPC resources
#
# Primary use: reach the existing *internal* storefront ALB (frontend-proxy-public)
# to open admin/observability paths blocked at CloudFront (/grafana, /jaeger, …).
# Does not create a second ALB. Path policy at the public edge stays on CloudFront.
#
# Auth: mutual TLS (operator-managed CA → ACM). Split tunnel by default.
# Cost: association hours per subnet — associate one AZ unless HA is required.
# ──────────────────────────────────────────────

locals {
  create = var.enabled

  # AmazonProvidedDNS is at base of VPC CIDR + 2 when using VPC DNS for clients.
  amazon_dns = var.vpc_cidr_block != "" ? [cidrhost(var.vpc_cidr_block, 2)] : []

  # Empty var.dns_servers → AmazonProvidedDNS; set var.dns_servers explicitly to override.
  # To push no DNS servers, pass a sentinel later if needed (not supported in v1).
  dns_servers = length(var.dns_servers) > 0 ? var.dns_servers : local.amazon_dns
}

# ──────────────────────────────────────────────
# Security group (Client VPN ENIs)
# ──────────────────────────────────────────────

resource "aws_security_group" "client_vpn" {
  count = local.create ? 1 : 0

  name_prefix = "${var.name}-"
  description = "Client VPN endpoint ENI security group"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name}-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpn_clients" {
  for_each = local.create ? toset(var.ingress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.client_vpn[0].id
  description       = "Allow Client VPN connections from ${each.value}"
  ip_protocol       = var.transport_protocol
  from_port         = var.vpn_port
  to_port           = var.vpn_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "to_vpc" {
  count = local.create ? 1 : 0

  security_group_id = aws_security_group.client_vpn[0].id
  description       = "Allow VPN clients to reach VPC resources"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr_block
}

# ──────────────────────────────────────────────
# Connection logging
# ──────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "client_vpn" {
  count = local.create && var.connection_log_enabled ? 1 : 0

  name              = "/aws/client-vpn/${var.name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.name}-logs"
  })
}

resource "aws_cloudwatch_log_stream" "client_vpn" {
  count = local.create && var.connection_log_enabled ? 1 : 0

  name           = "connections"
  log_group_name = aws_cloudwatch_log_group.client_vpn[0].name
}

# ──────────────────────────────────────────────
# Client VPN endpoint
# ──────────────────────────────────────────────

resource "aws_ec2_client_vpn_endpoint" "this" {
  count = local.create ? 1 : 0

  description            = var.name
  server_certificate_arn = var.server_certificate_arn
  client_cidr_block      = var.client_cidr_block
  split_tunnel           = var.split_tunnel
  transport_protocol     = var.transport_protocol
  vpn_port               = var.vpn_port
  vpc_id                 = var.vpc_id
  security_group_ids     = [aws_security_group.client_vpn[0].id]
  session_timeout_hours  = var.session_timeout_hours
  dns_servers            = local.dns_servers

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.client_root_certificate_chain_arn
  }

  connection_log_options {
    enabled               = var.connection_log_enabled
    cloudwatch_log_group  = var.connection_log_enabled ? aws_cloudwatch_log_group.client_vpn[0].name : null
    cloudwatch_log_stream = var.connection_log_enabled ? aws_cloudwatch_log_stream.client_vpn[0].name : null
  }

  tags = merge(var.tags, {
    Name = var.name
  })

  lifecycle {
    precondition {
      condition     = !local.create || (var.vpc_id != "" && var.vpc_cidr_block != "")
      error_message = "vpc_id and vpc_cidr_block are required when client VPN is enabled."
    }
    precondition {
      condition     = !local.create || length(var.subnet_ids) >= 1
      error_message = "subnet_ids must include at least one private subnet when client VPN is enabled."
    }
    precondition {
      condition = !local.create || (
        var.server_certificate_arn != "" &&
        var.client_root_certificate_chain_arn != ""
      )
      error_message = "server_certificate_arn and client_root_certificate_chain_arn are required when client VPN is enabled."
    }
    precondition {
      condition     = !local.create || length(var.ingress_cidr_blocks) >= 1
      error_message = "ingress_cidr_blocks must contain at least one CIDR when client VPN is enabled."
    }
  }
}

# ──────────────────────────────────────────────
# Network associations (1+ private subnets; default one AZ for cost)
# ──────────────────────────────────────────────

resource "aws_ec2_client_vpn_network_association" "this" {
  for_each = local.create ? toset(var.subnet_ids) : toset([])

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this[0].id
  subnet_id              = each.value
}

# ──────────────────────────────────────────────
# Authorization: all authenticated clients → VPC CIDR
# ──────────────────────────────────────────────

resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  count = local.create ? 1 : 0

  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this[0].id
  target_network_cidr    = var.vpc_cidr_block
  authorize_all_groups   = true
  description            = "Allow VPN clients access to VPC ${var.vpc_cidr_block}"
}

# ──────────────────────────────────────────────
# Optional: allow VPN client CIDR to internal ALB SG (TCP 80)
# Does not replace CloudFront VPC-origin rules on the same SG.
# ──────────────────────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "alb_from_vpn_clients" {
  for_each = local.create ? toset(var.alb_security_group_ids) : toset([])

  security_group_id = each.value
  # EC2 SG rule descriptions allow only ASCII from a fixed set (no Unicode).
  description       = "Client VPN clients to storefront internal ALB HTTP"
  ip_protocol       = "tcp"
  from_port         = var.alb_ingress_port
  to_port           = var.alb_ingress_port
  cidr_ipv4         = var.client_cidr_block
}
