variable "name" {
  type        = string
  description = "IAM role name (e.g. GitHubTerraformDevPlanRole)"
}

variable "description" {
  type        = string
  default     = null
  description = "Optional IAM role description"
}

variable "github_repository" {
  type        = string
  description = "GitHub repository in owner/name form (e.g. tf2-team/tf2-corp-infra)"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must be in the form owner/name."
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

variable "github_environments" {
  type        = list(string)
  default     = []
  description = <<-EOT
    GitHub Environments allowed to assume this role (OIDC sub repo:OWNER/REPO:environment:NAME).
    Use for apply roles (e.g. ["dev"] or ["production"]). Leave empty for plan roles that only use pull_request/refs.
  EOT
}

variable "allowed_refs" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Git refs allowed to assume this role (OIDC sub repo:OWNER/REPO:ref:<ref>).
    Examples: "refs/heads/main". Prefer empty for apply roles locked to Environments only.
  EOT
}

variable "allow_pull_request" {
  type        = bool
  default     = false
  description = "When true, allow OIDC subject repo:OWNER/REPO:pull_request (PR plan jobs)."
}

variable "permission_level" {
  type        = string
  description = "plan = ReadOnlyAccess + state backend; apply = PowerUser + IAM + state backend"

  validation {
    condition     = contains(["plan", "apply"], var.permission_level)
    error_message = "permission_level must be \"plan\" or \"apply\"."
  }
}

variable "state_bucket_arn" {
  type        = string
  description = "ARN of the Terraform S3 state bucket"
}

variable "state_kms_key_arn" {
  type        = string
  description = "ARN of the KMS key encrypting the state bucket"
}

variable "state_key_prefixes" {
  type        = list(string)
  description = <<-EOT
    State object key prefixes this role may read/write (no leading slash).
    Example: ["development/"] for dev CI, ["production/"] for prod CI.
    ListBucket is conditioned on these prefixes; object actions use prefix*.
  EOT

  validation {
    condition     = length(var.state_key_prefixes) > 0
    error_message = "At least one state_key_prefix is required."
  }

  validation {
    condition = alltrue([
      for p in var.state_key_prefixes :
      length(p) > 0 && !startswith(p, "/")
    ])
    error_message = "state_key_prefixes must be non-empty and must not start with /."
  }
}

variable "max_session_duration" {
  type        = number
  default     = 3600
  description = "Max session duration in seconds for the role (default 1h)"

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Additional tags for IAM resources"
}
