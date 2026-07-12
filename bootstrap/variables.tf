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

# ──────────────────────────────────────────────
# GitHub Actions → OIDC + ECR push roles
# Account-level; applied manually with bootstrap (not env CI).
# ──────────────────────────────────────────────

variable "github_actions_ecr_production" {
  type = object({
    role_name           = string
    github_repository   = string
    github_environments = list(string)
    allowed_refs        = list(string)
    ecr_project_name    = string
  })
  description = "Production platform CI role for GitHub Actions → ECR push (OIDC)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_actions_ecr_production.github_repository))
    error_message = "github_actions_ecr_production.github_repository must be owner/name."
  }

  validation {
    condition     = length(var.github_actions_ecr_production.github_environments) > 0
    error_message = "github_actions_ecr_production.github_environments must not be empty."
  }
}

variable "github_actions_ecr_development" {
  type = object({
    role_name           = string
    github_repository   = string
    github_environments = list(string)
    allowed_refs        = list(string)
    ecr_project_name    = string
  })
  description = "Development platform CI role for GitHub Actions → ECR push (OIDC)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_actions_ecr_development.github_repository))
    error_message = "github_actions_ecr_development.github_repository must be owner/name."
  }

  validation {
    condition     = length(var.github_actions_ecr_development.github_environments) > 0
    error_message = "github_actions_ecr_development.github_environments must not be empty."
  }
}
