variable "aws_region" {
  type        = string
  description = "Region định danh cho tài nguyên"
}

variable "project_name" {
  type        = string
  description = "Tên của dự án"
}

variable "tags" {
  type        = map(string)
  description = "Các tag được áp dụng cho tài nguyên"
}

variable "repositories" {
  type = map(object({
    image_tag_mutability = optional(string, "MUTABLE")
    scan_on_push         = optional(bool, true)
    keep_last_n_images   = optional(number, 10)
    force_delete         = optional(bool, true)
  }))
  description = "Bản đồ cấu hình các ECR repositories cần tạo"
}

variable "vpc_cidr_block" {
  type        = string
  description = "CIDR block cho VPC"
}

variable "public_subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = string
  }))
  description = "Bản đồ các Public Subnet"
}

variable "private_subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = string
    nat_gateway_key   = optional(string)
  }))
  default     = {}
  description = "Bản đồ các Private Subnet"
}

variable "nat_gateways" {
  type = map(object({
    public_subnet_key = string
  }))
  default     = {}
  description = "Bản đồ các NAT Gateway"
}

variable "cluster_name" {
  type        = string
  description = "Tên EKS cluster"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.36"
  description = "Phiên bản Kubernetes cho EKS cluster"
}

variable "node_groups" {
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2_x86_64")
    disk_size      = optional(number, 20)
    desired_size   = optional(number, 2)
    min_size       = optional(number, 1)
    max_size       = optional(number, 4)
    subnet_ids     = optional(list(string))
    labels         = optional(map(string), {})
  }))
  description = "Bản đồ các Managed Node Groups"
}

variable "addons" {
  type = map(object({
    addon_version            = optional(string)
    service_account_role_arn = optional(string)
  }))
  default     = {}
  description = "Bản đồ các EKS Managed Add-on"
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
