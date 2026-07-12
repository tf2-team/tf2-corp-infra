variable "name" {
  type        = string
  description = "Tên định danh cho VPC và các tài nguyên con (dùng làm prefix trong tag Name)"
}

variable "cidr_block" {
  type        = string
  description = "CIDR block của VPC (vd: 10.0.0.0/16)"
}

variable "enable_dns_hostnames" {
  type        = bool
  default     = true
  description = "Bật DNS hostname cho các instance trong VPC (bắt buộc khi dùng EKS)"
}

variable "enable_dns_support" {
  type        = bool
  default     = true
  description = "Bật DNS resolution trong VPC (bắt buộc khi dùng EKS)"
}

variable "public_subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = string
  }))
  description = <<-EOT
    Bản đồ các Public Subnet cần tạo.
    Key là tên ngắn dùng làm định danh trong các module khác.

    Ví dụ:
      public_subnets = {
        "pub-1a" = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1a" }
        "pub-1b" = { cidr_block = "10.0.2.0/24", availability_zone = "us-east-1b" }
      }
  EOT
}

variable "private_subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = string
    nat_gateway_key   = optional(string) # key từ var.nat_gateways; null = subnet cô lập, không có internet
  }))
  default     = {}
  description = <<-EOT
    Bản đồ các Private Subnet cần tạo.
    nat_gateway_key trỏ tới key trong var.nat_gateways để chọn NAT Gateway làm default route.
    Nếu null, subnet không có đường ra internet (isolated).

    Ví dụ — single NAT (tiết kiệm chi phí):
      private_subnets = {
        "priv-1a" = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a", nat_gateway_key = "nat-1a" }
        "priv-1b" = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b", nat_gateway_key = "nat-1a" }
      }

    Ví dụ — multi NAT (HA, tốn thêm ~$32/tuần/NAT):
      private_subnets = {
        "priv-1a" = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a", nat_gateway_key = "nat-1a" }
        "priv-1b" = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b", nat_gateway_key = "nat-1b" }
      }
  EOT
}

variable "nat_gateways" {
  type = map(object({
    public_subnet_key = string # key từ var.public_subnets — subnet đặt NAT Gateway này
  }))
  default     = {}
  description = <<-EOT
    Bản đồ các NAT Gateway cần tạo.
    Key được tham chiếu từ nat_gateway_key trong var.private_subnets.
    Mỗi NAT Gateway tốn ~$32/tuần — cân nhắc single vs multi theo ADR.

    Ví dụ:
      nat_gateways = {
        "nat-1a" = { public_subnet_key = "pub-1a" }
      }
  EOT
}

variable "eks_cluster_name" {
  type        = string
  default     = null
  description = <<-EOT
    Tên EKS cluster để gắn tag nhận diện subnet cho Load Balancer tự động.
    - Public subnets sẽ được gắn: kubernetes.io/role/elb = "1"
    - Private subnets sẽ được gắn: kubernetes.io/role/internal-elb = "1"
    Null = không gắn tag EKS (dùng khi VPC không phục vụ EKS).
  EOT
}

variable "enable_karpenter_discovery_tags" {
  type        = bool
  default     = true
  nullable    = false
  description = <<-EOT
    When true and eks_cluster_name is set, private subnets get
    karpenter.sh/discovery = <eks_cluster_name> for Karpenter EC2NodeClass selectors.
  EOT
}
