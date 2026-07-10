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
  description = "ECR project path segment (e.g. techx-corp). Full image: registry/ecr_project_name/service:tag"
  default     = "techx-corp"
}

variable "ecr_naming_mode" {
  type        = string
  description = "ECR naming: nested = project/service, flat = project-key"
  default     = "nested"
}

variable "ecr_keep_last_n_images" {
  type        = number
  description = "Lifecycle: keep N most recent images per service repo"
  default     = 20
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
    # AL2 only supported through k8s 1.32; AL2023 required for 1.33+
    ami_type     = optional(string, "AL2023_x86_64_STANDARD")
    disk_size    = optional(number, 20)
    desired_size = optional(number, 2)
    min_size     = optional(number, 1)
    max_size     = optional(number, 4)
    # Prefer subnet_keys (VPC private map keys, e.g. priv-1a) — resolved to IDs in main.tf
    subnet_keys = optional(list(string))
    # Optional raw IDs (overrides subnet_keys when set)
    subnet_ids = optional(list(string))
    labels     = optional(map(string), {})
    # Optional hard isolation taints (Phase 2). Prefer soft labels first.
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    # kubelet maxPods via launch template (pair with vpc-cni prefix delegation)
    max_pods = optional(number)
  }))
  description = "Managed Node Groups. Pin one group per AZ via subnet_keys for multi-AZ balance. Use workload-class=critical labels for the system/data floor."
}

variable "addons" {
  type = map(object({
    addon_version            = optional(string)
    service_account_role_arn = optional(string)
    configuration_values     = optional(string)
  }))
  default     = {}
  description = "Bản đồ các EKS Managed Add-on (optional configuration_values JSON for e.g. vpc-cni)"
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
  default     = "techx-gha-platform-prod"
}

variable "github_actions_environments" {
  type        = list(string)
  description = "GitHub Environments allowed to assume this role"
  default     = ["production"]
}

variable "github_actions_allowed_refs" {
  type        = list(string)
  description = "Optional extra git refs allowed (OIDC sub repo:...:ref:...)"
  default     = ["refs/heads/main", "refs/tags/v*"]
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = true
  nullable    = false
  description = "Create the account-level GitHub Actions OIDC provider (only one per account)"
}

variable "existing_github_oidc_provider_arn" {
  type        = string
  default     = null
  description = "ARN of an existing GitHub OIDC provider when create_github_oidc_provider is false"

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
  description = "Install Argo CD via Helm. Prefer enable on development first; keep false until prod cutover."
}

variable "argocd_chart_version" {
  type        = string
  default     = "7.8.28"
  description = "Pinned argo-helm argo-cd chart version"
}

variable "argocd_chart_repo_url" {
  type        = string
  default     = "https://github.com/tmcmanhcuong/techx-corp-chart.git"
  description = "Git URL of the Helm chart repo used by Argo CD Applications"
}

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm-applied)
# ──────────────────────────────────────────────
# Path rules are enforced by techx-corp-chart Ingress annotations (ALB Controller),
# not by raw AWS Terraform resources. These variables are the IaC source of truth
# for operators / deploy scripts.

variable "storefront_alb_block_sensitive_paths" {
  type        = bool
  default     = true
  nullable    = false
  description = <<-EOT
    Toggle ALB fixed-response 403 for sensitive paths on the public storefront Ingress.
    true  → BLOCK: /grafana, /jaeger, /loadgen, /feature, /flagservice, /otlp-http
            ALLOW: / , /api/* , /images/* (and other non-blocked prefixes via catch-all /)
    false → no path blocks; all prefixes forward to frontend-proxy

    Applied via Helm:
      --set components.frontend-proxy.publicAlb.blockSensitivePaths=<true|false>
    See outputs storefront_alb_helm_set_flags and storefront_alb_helm_deploy_command.
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
  description = "Sensitive path prefixes blocked when storefront_alb_block_sensitive_paths is true (must match chart values)"
}

# ──────────────────────────────────────────────
# SEC-05: Secrets Manager + External Secrets Operator
# ──────────────────────────────────────────────

variable "secrets_manager_name_prefix" {
  type        = string
  description = "ASM path prefix for secret shells (e.g. techx-corp/production)"
  default     = "techx-corp/production"
}

variable "secrets_manager_recovery_window_in_days" {
  type        = number
  description = "ASM recovery window for secret shells (0 = force delete; else 7–30)"
  default     = 30
}

variable "secrets_manager_kms_key_id" {
  type        = string
  description = "Optional CMK for ASM secrets (null = AWS managed key)"
  default     = null
}

variable "external_secrets_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "Create ESO IRSA + IAM policy scoped to ASM secret ARNs"
}

variable "external_secrets_install_helm" {
  type        = bool
  default     = false
  nullable    = false
  description = "Install ESO Helm chart from Terraform (requires cluster API at apply). Prefer false until kube path is ready; use helm_command output."
}

variable "external_secrets_create_cluster_secret_store" {
  type        = bool
  default     = false
  nullable    = false
  description = "Apply ClusterSecretStore via kubernetes_manifest (requires ESO CRDs installed)"
}

variable "external_secrets_chart_version" {
  type        = string
  default     = "0.14.4"
  description = "Pinned external-secrets Helm chart version"
}

# ──────────────────────────────────────────────
# Karpenter (node autoscaling)
# ──────────────────────────────────────────────

variable "karpenter_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "Create Karpenter IAM, node role, access entry, and interruption SQS"
}

variable "karpenter_install_helm" {
  type        = bool
  default     = false
  nullable    = false
  description = "Install Karpenter Helm chart (requires cluster API at apply)"
}

variable "karpenter_create_node_resources" {
  type        = bool
  default     = false
  nullable    = false
  description = "Apply EC2NodeClass + NodePool CRs (requires Helm CRDs)"
}

variable "karpenter_chart_version" {
  type        = string
  default     = "1.3.3"
  description = "Pinned Karpenter Helm chart version"
}

variable "karpenter_spot_preferred" {
  type        = bool
  default     = false
  nullable    = false
  description = "Prefer Spot NodePool (false = On-Demand only; recommended for production)"
}

variable "karpenter_nodepool_cpu_limit" {
  type        = string
  default     = "64"
  description = "NodePool CPU limit to cap spend"
}

variable "karpenter_nodepool_memory_limit" {
  type        = string
  default     = "128Gi"
  description = "NodePool memory limit to cap spend"
}

variable "karpenter_availability_zones" {
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
  description = "Zones allowed for Karpenter NodePools"
}

variable "karpenter_node_max_pods" {
  type        = number
  default     = 110
  nullable    = true
  description = "EC2NodeClass kubelet maxPods (pair with vpc-cni prefix delegation). null = AMI default."
}

variable "karpenter_min_instance_cpu" {
  type        = number
  default     = 2
  nullable    = false
  description = "Minimum vCPU for Karpenter nodes (0 disables). Avoids 1-vCPU instances with ~8 max pods."
}

# ──────────────────────────────────────────────
# Cluster Autoscaler (optional MNG/ASG scaler — OFF by default)
# ──────────────────────────────────────────────

variable "cluster_autoscaler_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Create Cluster Autoscaler IRSA role/policy and tag MNG ASGs for auto-discovery"
}

variable "cluster_autoscaler_install_helm" {
  type        = bool
  default     = false
  nullable    = false
  description = "Install Cluster Autoscaler Helm chart (requires cluster API; mutually exclusive with Karpenter install)"
}

variable "cluster_autoscaler_chart_version" {
  type        = string
  default     = "9.46.6"
  description = "Pinned cluster-autoscaler Helm chart version"
}

variable "plan_role_arn" {
  type        = string
  default     = null
  description = "IAM Role ARN of the GitHub Actions Plan Role to authorize in EKS"
}

