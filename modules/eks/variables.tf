variable "cluster_name" {
  type        = string
  description = "Tên EKS cluster"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.31"
  description = "Phiên bản Kubernetes cho EKS cluster"
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
    ami_type       = optional(string, "AL2_x86_64")
    disk_size      = optional(number, 20)
    desired_size   = optional(number, 2)
    min_size       = optional(number, 1)
    max_size       = optional(number, 4)
    subnet_ids     = optional(list(string))    # override subnet cho node group này, nếu null dùng var.subnet_ids
    labels         = optional(map(string), {}) # Kubernetes node labels
  }))
  description = <<-EOT
    Bản đồ các Managed Node Groups cần tạo.
    Key là tên ngắn của node group; tên thật sẽ là: {cluster_name}-{key}.

    Ví dụ:
      node_groups = {
        "general" = {
          instance_types = ["t3.medium"]
          desired_size   = 3
          min_size       = 2
          max_size       = 6
        }
        "spot" = {
          instance_types = ["t3.medium", "t3.large"]
          capacity_type  = "SPOT"
          desired_size   = 2
          min_size       = 1
          max_size       = 5
          labels         = { "workload-type" = "batch" }
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
        "aws-ebs-csi-driver" = { service_account_role_arn = aws_iam_role.ebs_csi.arn }
      }
  EOT
}
