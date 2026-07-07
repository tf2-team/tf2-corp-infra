variable "project_name" {
  type        = string
  description = "Tên dự án, dùng làm prefix cho tên ECR repository"
}

variable "repositories" {
  type = map(object({
    image_tag_mutability = optional(string, "MUTABLE")
    scan_on_push         = optional(bool, true)
    keep_last_n_images   = optional(number, 10)
    force_delete         = optional(bool, true)
  }))
  description = <<-EOT
    Bản đồ các ECR repository cần tạo.
    Key là tên ngắn của repo (không kèm prefix project).
    Tên repo thật sẽ là: {project_name}-{key}

    Ví dụ:
      repositories = {
        "frontend"      = {} 
        "product-catalog" = { keep_last_n_images = 5 }
        "llm"           = { image_tag_mutability = "IMMUTABLE", scan_on_push = false }
      }
  EOT
}
