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

variable "namespace" {
  type        = string
  description = "Kubernetes namespace Sigstore policy-controller runs in"
  default     = "cosign-system"
}

variable "service_account_name" {
  type        = string
  description = "policy-controller ServiceAccount name (IRSA trust subject)"
  default     = "policy-controller"
}

variable "cosign_kms_key_arn" {
  type        = string
  description = "Cosign KMS key ARN policy-controller must read the public key from to verify signatures (kms:GetPublicKey/DescribeKey only — no Sign, no Decrypt)"
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs policy-controller may pull image manifests/signatures from (supports trailing /* wildcards)"
}

variable "tags" {
  type        = map(string)
  description = "Tags for IAM resources"
  default     = {}
}
