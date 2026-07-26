variable "name" {
  type        = string
  description = "Resource name prefix (project name, e.g. techx-prod-tf2)"
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the EKS cluster OIDC provider"
}

variable "oidc_issuer_url" {
  type        = string
  description = "EKS cluster OIDC issuer URL (https://...)"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace of the exporter ServiceAccount"
}

variable "service_account_name" {
  type        = string
  description = "Name of the exporter ServiceAccount bound via IRSA"
  default     = "yace"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all IAM resources"
  default     = {}
}

# Change trail: @hungxqt - 2026-07-26 - IRSA role for YACE CloudWatch read-only metrics access.
