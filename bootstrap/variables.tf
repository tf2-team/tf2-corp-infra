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

# ──────────────────────────────────────────────
# GitHub Actions → Terraform plan/apply roles (infra repo)
# Account-level; applied manually with bootstrap (not env promote CI).
# ──────────────────────────────────────────────

variable "github_actions_terraform_development" {
  type = object({
    github_repository = string
    plan_role_name    = optional(string, "GitHubTerraformDevPlanRole")
    apply_role_name   = optional(string, "GitHubTerraformDevApplyRole")
    # GitHub Environment name on the infra repo (workflows use environment: dev)
    apply_github_environment = optional(string, "dev")
    # OIDC subjects for plan roles (PR + main + optional extra refs)
    plan_allowed_refs       = optional(list(string), ["refs/heads/main"])
    plan_allow_pull_request = optional(bool, true)
    # State key prefix for environments/development (trailing slash recommended)
    state_key_prefix = optional(string, "development/")
    # IAM role/policy name prefixes for apply (match env cluster_name; default techx-dev)
    iam_name_prefixes = optional(list(string), ["techx-dev"])
  })
  description = "Development infra-repo Terraform plan/apply OIDC roles (GitHub Actions)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_actions_terraform_development.github_repository))
    error_message = "github_actions_terraform_development.github_repository must be owner/name."
  }

  validation {
    condition     = length(var.github_actions_terraform_development.iam_name_prefixes) > 0
    error_message = "github_actions_terraform_development.iam_name_prefixes must not be empty (apply role IAM scope)."
  }
}

variable "github_actions_terraform_production" {
  type = object({
    github_repository = string
    plan_role_name    = optional(string, "GitHubTerraformProdPlanRole")
    apply_role_name   = optional(string, "GitHubTerraformProdApplyRole")
    # GitHub Environment name on the infra repo (workflows use environment: production)
    apply_github_environment = optional(string, "production")
    plan_allowed_refs        = optional(list(string), ["refs/heads/main"])
    plan_allow_pull_request  = optional(bool, true)
    state_key_prefix         = optional(string, "production/")
    # IAM role/policy name prefixes for apply (match env cluster_name; default techx-tf2-prod)
    iam_name_prefixes = optional(list(string), ["techx-tf2-prod"])
  })
  description = "Production infra-repo Terraform plan/apply OIDC roles (GitHub Actions)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_actions_terraform_production.github_repository))
    error_message = "github_actions_terraform_production.github_repository must be owner/name."
  }

  validation {
    condition     = length(var.github_actions_terraform_production.iam_name_prefixes) > 0
    error_message = "github_actions_terraform_production.iam_name_prefixes must not be empty (apply role IAM scope)."
  }
}
