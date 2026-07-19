variable "enabled" {
  type        = bool
  description = "When false, module creates no resources. When true, creates IRSA for hybrid CA on system MNG ASGs."
  default     = false
  nullable    = false
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name (auto-discovery tag + IAM naming)"
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
  description = "AWS region for Cluster Autoscaler cloud provider"
  default     = "us-east-1"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace for Cluster Autoscaler"
  default     = "kube-system"
}

variable "service_account_name" {
  type        = string
  description = "Controller ServiceAccount name (IRSA trust subject)"
  default     = "cluster-autoscaler"
}

variable "install_helm" {
  type        = bool
  description = "Install Cluster Autoscaler via Helm (requires cluster API at apply). Safe alongside Karpenter: CA owns tagged system MNG ASGs only."
  default     = false
  nullable    = false
}

variable "chart_version" {
  type        = string
  description = "Pinned cluster-autoscaler Helm chart version (kubernetes/autoscaler charts)"
  default     = "9.46.6"
}

variable "timeout_seconds" {
  type        = number
  description = "Helm install/upgrade timeout"
  default     = 600
}

variable "scale_down_delay_after_add" {
  type        = string
  description = "How long after scale-up before CA considers scale-down"
  default     = "10m"
}

variable "scale_down_unneeded_time" {
  type        = string
  description = "How long a node must be unneeded before scale-down"
  default     = "10m"
}

variable "balance_similar_node_groups" {
  type        = bool
  description = "Balance capacity across similar node groups (recommended for multi-AZ MNGs)"
  default     = true
  nullable    = false
}

variable "skip_nodes_with_system_pods" {
  type        = bool
  description = "If true, CA will not scale down nodes running non-DaemonSet system pods"
  default     = true
  nullable    = false
}

variable "tags" {
  type        = map(string)
  description = "Tags for IAM resources"
  default     = {}
}

# Change trail: @hungxqt - 2026-07-19 - Clarify hybrid CA+Karpenter install_helm semantics.

