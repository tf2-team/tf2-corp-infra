variable "name" {
  type        = string
  description = "Stable environment-specific name prefix"
}

variable "aws_region" {
  type        = string
  description = "AWS region containing the S3 bucket and VPC"
}

variable "vpc_id" {
  type        = string
  description = "VPC that receives the S3 gateway endpoint"
}

variable "private_route_table_ids" {
  type        = list(string)
  description = "Private route tables used by EKS nodes"
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
  default     = "techx-corp"
  description = "Namespace containing product-reviews"
}

variable "service_account_name" {
  type        = string
  default     = "product-reviews"
  description = "IRSA-enabled product-reviews ServiceAccount"
}

variable "model_prefix" {
  type        = string
  default     = "protectai/deberta-v3-base-prompt-injection-v2/"
  description = "Only S3 prefix the workload may read"
}

variable "tags" {
  type    = map(string)
  default = {}
}
