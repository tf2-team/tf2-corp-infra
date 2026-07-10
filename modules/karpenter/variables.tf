variable "enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When false, module creates no resources"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name"
}

variable "cluster_endpoint" {
  type        = string
  description = "EKS API server endpoint (Helm settings.clusterEndpoint)"
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS IAM OIDC provider ARN for IRSA"
}

variable "oidc_issuer_url" {
  type        = string
  description = "EKS OIDC issuer URL (https://oidc.eks...)"
}

variable "aws_region" {
  type        = string
  description = "AWS region for IAM resource ARNs and EventBridge"
  default     = "us-east-1"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for Karpenter controller"
  default     = "kube-system"
}

variable "service_account_name" {
  type        = string
  description = "Karpenter controller ServiceAccount name (IRSA trust subject)"
  default     = "karpenter"
}

variable "install_helm" {
  type        = bool
  default     = false
  nullable    = false
  description = "Install Karpenter Helm chart (requires cluster API reachable at apply)"
}

variable "create_node_resources" {
  type        = bool
  default     = false
  nullable    = false
  description = "Apply EC2NodeClass + NodePool(s) via kubernetes_manifest (requires CRDs from Helm)"
}

variable "chart_version" {
  type        = string
  description = "Pinned Karpenter Helm chart version (oci://public.ecr.aws/karpenter/karpenter)"
  default     = "1.3.3"
}

variable "timeout_seconds" {
  type        = number
  description = "Helm install/upgrade timeout"
  default     = 600
}

variable "discovery_tag_value" {
  type        = string
  description = "Value for karpenter.sh/discovery on subnets/SG (usually cluster_name)"
}

variable "node_iam_role_name" {
  type        = string
  description = "IAM role name for Karpenter-provisioned nodes (EC2NodeClass spec.role)"
  default     = null
}

variable "controller_iam_role_name" {
  type        = string
  description = "IAM role name for Karpenter controller IRSA"
  default     = null
}

variable "spot_preferred" {
  type        = bool
  default     = false
  nullable    = false
  description = <<-EOT
    When true (development): primary NodePool uses Spot (high weight) plus a lower-weight
    On-Demand fallback NodePool.
    When false (production): single On-Demand NodePool.
  EOT
}

variable "instance_categories" {
  type        = list(string)
  default     = ["c", "m", "r"]
  description = "karpenter.k8s.aws/instance-category allow-list"
}

variable "ami_alias" {
  type        = string
  default     = "al2023@latest"
  description = "EC2NodeClass amiSelectorTerms alias (e.g. al2023@latest)"
}

variable "nodepool_cpu_limit" {
  type        = string
  default     = "32"
  description = "NodePool CPU limit (string for Kubernetes quantity)"
}

variable "nodepool_memory_limit" {
  type        = string
  default     = "64Gi"
  description = "NodePool memory limit"
}

variable "expire_after" {
  type        = string
  default     = "720h"
  description = "NodePool expireAfter (empty string disables)"
}

variable "consolidate_after" {
  type        = string
  default     = "1m"
  description = "NodePool disruption consolidateAfter"
}

variable "availability_zones" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "Allowed topology.kubernetes.io/zone values for NodePools"
}

variable "ec2nodeclass_name" {
  type        = string
  default     = "default"
  description = "EC2NodeClass metadata.name"
}

variable "tags" {
  type        = map(string)
  description = "Tags for IAM / SQS resources"
  default     = {}
}
