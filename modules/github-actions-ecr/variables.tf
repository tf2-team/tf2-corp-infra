variable "name" {
  type        = string
  description = "IAM role name (e.g. techx-gha-platform-prod)"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository in owner/name form (e.g. tmcmanhcuong/tf2-corp-platform)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in the form owner/name."
  }
}

variable "github_environments" {
  type        = list(string)
  description = "GitHub Environments allowed to assume this role (e.g. [\"production\"])"

  validation {
    condition     = length(var.github_environments) > 0
    error_message = "At least one GitHub Environment must be specified."
  }
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the account-level GitHub Actions OIDC provider (created by bootstrap)"

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:oidc-provider/.+$", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be a valid IAM OIDC provider ARN."
  }
}

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs this role may push images to (supports trailing /* wildcards)"

  validation {
    condition     = length(var.ecr_repository_arns) > 0
    error_message = "At least one ECR repository ARN is required."
  }
}

variable "allowed_refs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Optional extra git refs allowed to assume the role (in addition to GitHub Environments).
    Examples: "refs/heads/main", "refs/heads/techx-dev-corp", "refs/tags/v*"
    Rendered as OIDC subjects: repo:OWNER/REPO:ref:<ref>
  EOT
}

variable "s3_publish_bucket_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Optional S3 bucket ARNs this role may ListBucket on when publishing CI model
    artifacts (e.g. Mem0 FastEmbed). Empty disables the S3 publish statement.
  EOT
}

variable "s3_publish_object_arns" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Optional S3 object ARNs (with /* suffixes) this role may GetObject/PutObject
    on for model artifact publish and retag. Must be non-empty when
    s3_publish_bucket_arns is set.
  EOT

  validation {
    condition = (
      (length(var.s3_publish_bucket_arns) == 0 && length(var.s3_publish_object_arns) == 0) ||
      (length(var.s3_publish_bucket_arns) > 0 && length(var.s3_publish_object_arns) > 0)
    )
    error_message = "s3_publish_bucket_arns and s3_publish_object_arns must both be empty or both non-empty."
  }
}

variable "s3_publish_list_prefixes" {
  type        = list(string)
  default     = []
  description = <<-EOT
    s3:prefix values for ListBucket conditions (no leading slash). Example:
    "fastembed/paraphrase-multilingual-MiniLM-L12-v2/*". Required when
    s3_publish_bucket_arns is non-empty.
  EOT

  validation {
    condition = (
      length(var.s3_publish_bucket_arns) == 0 ||
      length(var.s3_publish_list_prefixes) > 0
    )
    error_message = "s3_publish_list_prefixes is required when s3_publish_bucket_arns is set."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags for IAM resources"
}
# Change trail: @hungxqt - 2026-07-19 - Optional S3 model-artifact publish permissions for GHA ECR roles.
