variable "aws_region" {
  type        = string
  description = "Region định danh cho tài nguyên"
}

variable "project_name" {
  type        = string
  description = "Tên của dự án (default tags / naming prefix)"
}

variable "tags" {
  type        = map(string)
  description = "Các tag được áp dụng cho tài nguyên"
}

# ──────────────────────────────────────────────
# ECR (same variable contract and defaults as production)
# ──────────────────────────────────────────────

variable "ecr_project_name" {
  type        = string
  description = "ECR project path segment (e.g. techx-dev-corp). Full image: registry/ecr_project_name/service:tag"
  default     = "techx-dev-corp"
}

variable "ecr_naming_mode" {
  type        = string
  description = "ECR naming: nested = project/service, flat = project-key"
  default     = "nested"
}

variable "ecr_keep_last_n_images" {
  type        = number
  description = "Lifecycle: keep N recent ECR records per repo; 25 retains about five multi-arch BuildKit releases including attestations"
  default     = 25
}

variable "ecr_keep_last_n_buildcache" {
  type        = number
  description = "Lifecycle: keep N most recent :buildcache-tagged images per service repo (0 = expire all buildcache after 1 day)"
  default     = 0
}

variable "ecr_scan_on_push" {
  type        = bool
  description = "Enable ECR scan on push"
  default     = true
}

variable "ecr_force_delete" {
  type        = bool
  description = "Allow destroying non-empty ECR repositories"
  default     = true
}

variable "ecr_image_tag_mutability" {
  type        = string
  description = "ECR image tag mutability for all service repositories (MUTABLE or IMMUTABLE)"
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.ecr_image_tag_mutability)
    error_message = "ecr_image_tag_mutability must be \"MUTABLE\" or \"IMMUTABLE\"."
  }
}

variable "ecr_repository_overrides" {
  type = map(object({
    image_tag_mutability   = optional(string)
    scan_on_push           = optional(bool)
    keep_last_n_images     = optional(number)
    keep_last_n_buildcache = optional(number)
    force_delete           = optional(bool)
  }))
  default     = {}
  description = "Optional per-service ECR setting overrides (module ships full platform catalog)"
}

# Change trail: @hungxqt - 2026-07-25 - Drop non-ECR variables; ECR defaults match production.
