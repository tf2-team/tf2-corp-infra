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

variable "ecr_repository_arns" {
  type        = list(string)
  description = "ECR repository ARNs this role may push images to"

  validation {
    condition     = length(var.ecr_repository_arns) > 0
    error_message = "At least one ECR repository ARN is required."
  }
}

variable "create_oidc_provider" {
  type        = bool
  default     = true
  nullable    = false
  description = "Create the account-level GitHub OIDC provider. Only one provider may exist per AWS account — set false in secondary environments."
}

variable "existing_oidc_provider_arn" {
  type        = string
  default     = null
  description = "ARN of an existing GitHub OIDC provider. Used when create_oidc_provider is false. If null, looks up by URL."

  validation {
    condition     = var.existing_oidc_provider_arn == null ? true : can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:oidc-provider/.+$", var.existing_oidc_provider_arn))
    error_message = "existing_oidc_provider_arn must be a valid IAM OIDC provider ARN."
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

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags for IAM resources"
}
