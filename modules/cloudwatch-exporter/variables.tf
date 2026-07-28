variable "name" {
  type        = string
  description = "Resource name prefix"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS IAM OIDC provider ARN"
}

variable "oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL"
}

variable "namespace" {
  type        = string
  description = "Namespace containing the YACE ServiceAccount"
}

variable "service_account_name" {
  type        = string
  description = "YACE ServiceAccount name"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to IAM resources"
  default     = {}
}

# Change trail: AIO4 - 2026-07-26 - Define YACE CloudWatch exporter IRSA inputs.
