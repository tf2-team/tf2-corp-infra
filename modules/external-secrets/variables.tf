variable "enabled" {
  type        = bool
  description = "When false, module creates no resources"
  default     = true
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (used in IAM role naming)"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS IAM OIDC provider ARN for IRSA"
}

variable "oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL (https://oidc.eks...)"
}

variable "secret_arns" {
  type        = list(string)
  description = "Exact ASM secret ARNs ESO may read (least privilege)"
}

variable "aws_region" {
  type        = string
  description = "AWS region for ClusterSecretStore"
  default     = "us-east-1"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for ESO"
  default     = "external-secrets"
}

variable "service_account_name" {
  type        = string
  description = "ESO controller ServiceAccount name (IRSA trust subject)"
  default     = "external-secrets"
}

variable "install_helm" {
  type        = bool
  description = "Install ESO via Helm (requires cluster API reachable at apply)"
  default     = false
}

variable "create_cluster_secret_store" {
  type        = bool
  description = "Apply ClusterSecretStore aws-secretsmanager (requires install_helm or existing ESO CRDs)"
  default     = false
}

variable "chart_version" {
  type        = string
  description = "Pinned external-secrets Helm chart version"
  default     = "0.14.4"
}

variable "timeout_seconds" {
  type        = number
  description = "Helm install/upgrade timeout"
  default     = 600
}

variable "cluster_secret_store_name" {
  type        = string
  description = "ClusterSecretStore metadata.name"
  default     = "aws-secretsmanager"
}

variable "tags" {
  type        = map(string)
  description = "Tags for IAM resources"
  default     = {}
}
