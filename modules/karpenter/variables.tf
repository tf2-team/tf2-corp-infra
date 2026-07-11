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
  description = "Apply EC2NodeClass + NodePool(s) via local Helm chart (installs/uses karpenter-crd first)"
}

variable "chart_version" {
  type        = string
  description = "Pinned Karpenter Helm chart version (oci://public.ecr.aws/karpenter/karpenter). Pin karpenter-crd and karpenter to the same version."
  default     = "1.13.1"
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
    When true (development): create stateless-spot (high weight) and stateless-on-demand (low weight).
    When false (production initial): only stateless-on-demand NodePool.
  EOT
}

variable "node_taints" {
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default     = []
  description = "Taints applied to Karpenter NodePools (both Spot and On-Demand when present)."

  validation {
    condition = alltrue([
      for t in var.node_taints : length(trimspace(t.key)) > 0
    ])
    error_message = "Each karpenter node taint key must be non-empty."
  }

  validation {
    condition = alltrue([
      for t in var.node_taints : contains(["NoSchedule", "PreferNoSchedule", "NoExecute"], t.effect)
    ])
    error_message = "Each karpenter node taint effect must be NoSchedule, PreferNoSchedule, or NoExecute."
  }

  validation {
    condition = length(var.node_taints) == length(distinct([
      for t in var.node_taints : "${t.key}|${t.value}|${t.effect}"
    ]))
    error_message = "Duplicate karpenter node taint key/value/effect triples are not allowed."
  }
}

variable "nodepool_weights" {
  type = object({
    spot      = number
    on_demand = number
  })
  default = {
    spot      = 100
    on_demand = 10
  }
  description = "Scheduling preference weights for Karpenter NodePools (higher preferred first)."

  validation {
    condition     = var.nodepool_weights.spot >= 0 && var.nodepool_weights.on_demand >= 0
    error_message = "Both NodePool weights must be greater than or equal to 0."
  }
}

variable "disruption_budget_nodes" {
  type = object({
    spot      = string
    on_demand = string
  })
  default = {
    spot      = "1"
    on_demand = "1"
  }
  description = <<-EOT
    Per-NodePool voluntary disruption limits (Karpenter budget nodes string).
    Accepts absolute counts (e.g. "0", "1") or percentages (e.g. "10%", "100%").
    Budgets are per NodePool, not a single global cluster limit.
  EOT

  validation {
    condition = alltrue([
      for v in [var.disruption_budget_nodes.spot, var.disruption_budget_nodes.on_demand] :
      can(regex("^(0|[1-9][0-9]*|([1-9]|[1-9][0-9]|100)%)$", v))
    ])
    error_message = "disruption_budget_nodes values must be a non-negative integer (e.g. \"0\", \"1\") or a percentage from 1% to 100% (e.g. \"10%\", \"100%\")."
  }
}

variable "instance_categories" {
  type        = list(string)
  default     = ["c", "m", "r"]
  description = "karpenter.k8s.aws/instance-category allow-list"
}

variable "min_instance_cpu" {
  type        = number
  default     = 2
  nullable    = false
  description = <<-EOT
    Minimum vCPU for Karpenter-provisioned nodes (karpenter.k8s.aws/instance-cpu Gt min-1).
    Default 2 avoids 1-vCPU instances (e.g. c7a.medium) that only allow ~8 pods and leave
    almost no room after DaemonSets (aws-node, kube-proxy, ebs-csi-node, otel-agent).
    Set to 0 to disable the requirement.
  EOT
}

variable "node_max_pods" {
  type        = number
  default     = 110
  nullable    = true
  description = <<-EOT
    kubelet maxPods on Karpenter nodes (EC2NodeClass spec.kubelet.maxPods).
    Pair with cluster-wide VPC CNI prefix delegation. Set null to omit (AMI default).
  EOT
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
