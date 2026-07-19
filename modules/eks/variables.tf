variable "cluster_name" {
  type        = string
  description = "Tên EKS cluster"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.31"
  description = "Phiên bản Kubernetes cho EKS cluster"
}

variable "upgrade_policy_support_type" {
  type        = string
  default     = "STANDARD"
  nullable    = false
  description = <<-EOT
    EKS cluster upgrade policy support type:
      STANDARD  — standard support only (default; upgrade before standard EOL)
      EXTENDED  — extended support after standard EOL (additional AWS charges)
  EOT

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.upgrade_policy_support_type)
    error_message = "upgrade_policy_support_type must be STANDARD or EXTENDED."
  }
}

variable "subnet_ids" {
  type        = list(string)
  description = "Danh sách subnet IDs cho cluster control plane và node groups (mặc định). Nên gồm cả public và private subnets."
}

variable "enabled_cluster_log_types" {
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
  nullable    = false
  description = "EKS control-plane log types to enable. Keep audit visibility on for Directive #11."

  validation {
    condition = alltrue([
      for log_type in var.enabled_cluster_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], log_type)
    ])
    error_message = "enabled_cluster_log_types may contain only api, audit, authenticator, controllerManager, or scheduler."
  }
}

variable "endpoint_public_access" {
  type        = bool
  default     = true
  description = "Cho phép truy cập Kubernetes API server từ internet"
}

variable "endpoint_private_access" {
  type        = bool
  default     = true
  description = "Cho phép truy cập Kubernetes API server từ trong VPC"
}

variable "public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "Danh sách CIDR block được phép truy cập public endpoint. Nên giới hạn lại trong production."
}

variable "node_groups" {
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND") # ON_DEMAND | SPOT
    # AL2 only supported through k8s 1.32; AL2023 required for 1.33+
    ami_type     = optional(string, "AL2023_x86_64")
    disk_size    = optional(number, 20)
    desired_size = optional(number, 2)
    min_size     = optional(number, 1)
    max_size     = optional(number, 4)
    # Pin to specific subnets (one AZ) for multi-AZ balance; null = all var.subnet_ids
    subnet_ids = optional(list(string))
    labels     = optional(map(string), {}) # Kubernetes node labels
    # Optional taints for hard isolation (Phase 2 workload placement).
    # Example: [{ key = "workload-class", value = "critical", effect = "NO_SCHEDULE" }]
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
    })), [])
    # When set, creates a launch template with AL2023 NodeConfig kubelet.maxPods.
    # Use with VPC CNI prefix delegation (e.g. 110 for t3.large). Requires node recycle.
    max_pods = optional(number)
  }))
  description = <<-EOT
    Managed Node Groups. Key is short name; resource name = {cluster_name}-{key}.

    For multi-AZ balance, create one group per AZ and set subnet_ids to a single
    private subnet (env main.tf resolves subnet_keys from the VPC module).

    Labels: use workload-class=critical for the system/data floor (see docs/workload-placement.md).
    Taints: optional hard isolation; only enable after critical pods and DaemonSets have matching tolerations.

    max_pods: optional kubelet maxPods via launch template (AL2023 NodeConfig).
    Pair with vpc-cni ENABLE_PREFIX_DELEGATION for higher density than default ENI mode
    (t3.large default maxPods=35 → ~110 with prefix mode).

    Example (env tfvars uses subnet_keys; main.tf maps to subnet_ids):
      node_groups = {
        "general-1a" = {
          instance_types = ["t3.large"]
          capacity_type  = "ON_DEMAND"
          desired_size   = 1
          min_size       = 1
          max_size       = 2
          max_pods       = 110
          subnet_keys    = ["priv-1a"]
          labels = {
            role           = "critical"
            workload-class = "critical"
            az             = "us-east-1a"
          }
        }
      }
  EOT
}

variable "addons" {
  type = map(object({
    addon_version            = optional(string) # null = dùng default version của EKS
    service_account_role_arn = optional(string) # IRSA ARN cho addon cần quyền IAM (vd: aws-ebs-csi-driver, vpc-cni)
    # JSON string for EKS addon configurationValues (e.g. vpc-cni prefix delegation).
    configuration_values = optional(string)
  }))
  default     = {}
  description = <<-EOT
    Bản đồ các EKS Managed Add-on cần cài.
    Key là tên addon chính xác theo AWS (vd: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver).

    Ví dụ (prefix delegation for higher pod density).
    In .tfvars use a raw JSON string (functions are not allowed in tfvars):
      configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\",\"WARM_PREFIX_TARGET\":\"1\"}}"
    In .tf files you may use jsonencode({ env = { ... } }).

    Example:
      addons = {
        "vpc-cni" = {
          configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\",\"WARM_PREFIX_TARGET\":\"1\"}}"
        }
        "coredns"            = {}
        "kube-proxy"         = {}
        # service_account_role_arn optional: module auto-wires IRSA for aws-ebs-csi-driver
        "aws-ebs-csi-driver" = {}
      }
  EOT
}

variable "enable_karpenter_discovery_tags" {
  type        = bool
  default     = true
  nullable    = false
  description = <<-EOT
    Tag the EKS cluster security group with karpenter.sh/discovery = cluster_name
    so Karpenter EC2NodeClass can select it for provisioned nodes.
  EOT
}

variable "enable_cluster_autoscaler_asg_tags" {
  type        = bool
  default     = false
  nullable    = false
  description = <<-EOT
    Tag matching managed node group ASGs for Cluster Autoscaler auto-discovery:
      k8s.io/cluster-autoscaler/enabled = true
      k8s.io/cluster-autoscaler/<cluster_name> = owned
    Only node group map keys whose names start with a value in
    cluster_autoscaler_node_group_name_prefixes are tagged (default: system-).
    Enable when cluster_autoscaler_enabled is true. Safe alongside Karpenter
    (CA owns tagged MNG ASGs only; Karpenter owns non-ASG Spot/OD nodes).
  EOT
}

variable "cluster_autoscaler_node_group_name_prefixes" {
  type        = list(string)
  default     = ["system-"]
  nullable    = false
  description = <<-EOT
    Node group map-key prefixes that receive Cluster Autoscaler ASG discovery tags
    when enable_cluster_autoscaler_asg_tags is true. Default system- matches
    system-1a / system-1b critical floor groups. Leave empty to tag no groups.
  EOT

  validation {
    condition = alltrue([
      for prefix in var.cluster_autoscaler_node_group_name_prefixes :
      length(trimspace(prefix)) > 0
    ])
    error_message = "cluster_autoscaler_node_group_name_prefixes entries must be non-empty strings."
  }
}

variable "create_oidc_provider" {
  type        = bool
  default     = true
  nullable    = false
  description = "Quyết định xem có tạo IAM OIDC provider mới hay không"
}

variable "existing_oidc_provider_arn" {
  type        = string
  default     = null
  description = "ARN của IAM OIDC provider đã tồn tại"

  validation {
    condition     = var.existing_oidc_provider_arn == null ? true : can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:oidc-provider/.+$", var.existing_oidc_provider_arn))
    error_message = "The existing_oidc_provider_arn must be a valid IAM OIDC provider ARN matching the format: arn:<partition>:iam::<account>:oidc-provider/..."
  }
}

variable "plan_role_arn" {
  type        = string
  default     = null
  description = "IAM Role ARN of the GitHub Actions Plan Role to authorize in EKS"
}

variable "access_entries" {
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    policy_arn        = optional(string)
  }))
  default     = {}
  description = "Bản đồ các EKS Access Entries bổ sung cần cấu hình"
}

# Change trail: @hungxqt - 2026-07-19 - Add cluster_autoscaler_node_group_name_prefixes for system-only CA tags.

