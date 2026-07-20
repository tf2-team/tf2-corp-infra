variable "name" {
  type        = string
  description = "Resource name prefix"
}

variable "vpc_id" {
  type        = string
  description = "VPC hosting EKS and the private Valkey endpoint"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets spanning at least two availability zones"
}

variable "eks_client_security_group_id" {
  type        = string
  description = "Security group attached to EKS worker nodes allowed to reach Valkey"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS IAM OIDC provider ARN"
}

variable "oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL"
}

variable "checkout_namespace" {
  type        = string
  default     = "techx-corp-prod"
  description = "Kubernetes namespace containing checkout"
}

variable "checkout_service_account" {
  type        = string
  default     = "checkout"
  description = "IRSA-enabled checkout ServiceAccount name"
}

variable "valkey_node_type" {
  type        = string
  default     = "cache.t4g.micro"
  description = "Small Graviton node class for the cart cache"
}

variable "valkey_engine_version" {
  type        = string
  default     = "8.0"
  description = "ElastiCache Valkey engine version"
}

variable "private_dns_zone" {
  type        = string
  default     = "techx.internal"
  description = "Route53 private hosted zone used for stable application endpoints"
}

variable "valkey_snapshot_retention_limit" {
  type        = number
  default     = 7
  description = "Days of automated Valkey snapshots to retain (MANDATE-20 retention; RPO remains daily cadence)"
}

variable "valkey_snapshot_window" {
  type        = string
  default     = "18:00-19:00"
  description = "Daily ElastiCache snapshot window (UTC)"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to resources"
}

# Change trail: @hungxqt - 2026-07-20 - Parameterize Valkey snapshot retention for Mandate 20.
