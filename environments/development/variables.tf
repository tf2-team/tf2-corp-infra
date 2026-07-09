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
  description = "Lifecycle: keep N most recent images per service repo"
  default     = 10
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

variable "ecr_repository_overrides" {
  type = map(object({
    image_tag_mutability = optional(string)
    scan_on_push         = optional(bool)
    keep_last_n_images   = optional(number)
    force_delete         = optional(bool)
  }))
  default     = {}
  description = "Optional per-service ECR setting overrides (module ships full platform catalog)"
}

# ──────────────────────────────────────────────
# VPC Variables
# ──────────────────────────────────────────────

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

# ──────────────────────────────────────────────
# EKS Variables
# ──────────────────────────────────────────────

variable "cluster_name" {
  type        = string
  description = "Tên EKS cluster"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.31"
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

# ──────────────────────────────────────────────
# GitHub Actions → ECR push (OIDC)
# ──────────────────────────────────────────────

variable "github_repository" {
  type        = string
  description = "GitHub repository (owner/name) allowed to assume the ECR push role"
  default     = "tmcmanhcuong/tf2-corp-platform"
}

variable "github_actions_ecr_role_name" {
  type        = string
  description = "IAM role name for GitHub Actions ECR push"
  default     = "techx-gha-platform-dev"
}

variable "github_actions_environments" {
  type        = list(string)
  description = "GitHub Environments allowed to assume this role"
  default     = ["development"]
}

variable "github_actions_allowed_refs" {
  type        = list(string)
  description = "Optional extra git refs allowed (OIDC sub repo:...:ref:...)"
  default     = ["refs/heads/techx-dev-corp"]
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = false
  nullable    = false
  description = "Create the account-level GitHub Actions OIDC provider. Default false — production creates it; development looks it up."
}

variable "existing_github_oidc_provider_arn" {
  type        = string
  default     = null
  description = "ARN of an existing GitHub OIDC provider when create_github_oidc_provider is false (null = lookup by URL)"

  validation {
    condition     = var.existing_github_oidc_provider_arn == null ? true : can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:oidc-provider/.+$", var.existing_github_oidc_provider_arn))
    error_message = "existing_github_oidc_provider_arn must be a valid IAM OIDC provider ARN."
  }
}

# ──────────────────────────────────────────────
# Argo CD (GitOps control plane — REL-09)
# ──────────────────────────────────────────────

variable "argocd_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Install Argo CD via Helm into the cluster. Requires API access at terraform apply time."
}

variable "argocd_chart_version" {
  type        = string
  default     = "7.8.28"
  description = "Pinned argo-helm argo-cd chart version"
}

variable "argocd_chart_repo_url" {
  type        = string
  default     = "https://github.com/tmcmanhcuong/techx-corp-chart.git"
  description = "Git URL of the Helm chart repo used by Argo CD Applications (document only; apps live in chart gitops/)"
}

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm-applied)
# ──────────────────────────────────────────────

variable "storefront_alb_block_sensitive_paths" {
  type        = bool
  default     = true
  nullable    = false
  description = <<-EOT
    Toggle ALB fixed-response 403 for sensitive paths on the public storefront Ingress.
    true  → BLOCK: /grafana, /jaeger, /loadgen, /feature, /flagservice, /otlp-http
            ALLOW: / , /api/* , /images/* (via catch-all /)
    false → no path blocks

    Applied via Helm --set components.frontend-proxy.publicAlb.blockSensitivePaths=<bool>
  EOT
}

variable "storefront_alb_blocked_prefixes" {
  type = list(string)
  default = [
    "/grafana",
    "/jaeger",
    "/loadgen",
    "/feature",
    "/flagservice",
    "/otlp-http",
  ]
  description = "Sensitive path prefixes blocked when storefront_alb_block_sensitive_paths is true"
}
