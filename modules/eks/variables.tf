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
  }))
  description = <<-EOT
    Managed Node Groups. Key is short name; resource name = {cluster_name}-{key}.

    For multi-AZ balance, create one group per AZ and set subnet_ids to a single
    private subnet (env main.tf resolves subnet_keys from the VPC module).

    Example (env tfvars uses subnet_keys; main.tf maps to subnet_ids):
      node_groups = {
        "general-1a" = {
          instance_types = ["t3.large"]
          desired_size   = 1
          min_size       = 1
          max_size       = 2
          subnet_keys    = ["priv-1a"]
          labels         = { az = "us-east-1a" }
        }
        "general-1b" = {
          instance_types = ["t3.large"]
          desired_size   = 1
          min_size       = 1
          max_size       = 2
          subnet_keys    = ["priv-1b"]
          labels         = { az = "us-east-1b" }
        }
      }
  EOT
}

variable "addons" {
  type = map(object({
    addon_version            = optional(string) # null = dùng default version của EKS
    service_account_role_arn = optional(string) # IRSA ARN cho addon cần quyền IAM (vd: aws-ebs-csi-driver, vpc-cni)
  }))
  default     = {}
  description = <<-EOT
    Bản đồ các EKS Managed Add-on cần cài.
    Key là tên addon chính xác theo AWS (vd: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver).

    Ví dụ:
      addons = {
        "vpc-cni"            = {}
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
    Tag each managed node group ASG for Cluster Autoscaler auto-discovery:
      k8s.io/cluster-autoscaler/enabled = true
      k8s.io/cluster-autoscaler/<cluster_name> = owned
    Enable when cluster_autoscaler_enabled is true. Harmless if CA Helm is not installed.
  EOT
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

