variable "aws_region" {
  type        = string
  description = "Region định danh cho tài nguyên"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Tên của dự án"
  default     = "techx"
}

variable "tags" {
  type        = map(string)
  description = "Các tag được áp dụng cho tài nguyên"
  default = {
    Environment = "bootstrap"
    ManagedBy   = "Terraform"
    Project     = "techx-platform"
  }
}
