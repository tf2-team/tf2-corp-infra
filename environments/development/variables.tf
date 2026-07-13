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
  description = "Lifecycle: keep N most recent non-buildcache images per service repo (aligned with production: 5)"
  default     = 5
}

variable "ecr_keep_last_n_buildcache" {
  type        = number
  description = "Lifecycle: keep N most recent :buildcache-tagged images per service repo (default 1)"
  default     = 1
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
    image_tag_mutability   = optional(string)
    scan_on_push           = optional(bool)
    keep_last_n_images     = optional(number)
    keep_last_n_buildcache = optional(number)
    force_delete           = optional(bool)
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
  default     = "https://github.com/tf2-team/tf2-corp-chart.git"
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

    Both environments override this to false in terraform.tfvars (open storefront paths).
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
  description = "ASM path prefix for secret shells (e.g. techx-corp/development)"
  default     = "techx-corp/development"
}

variable "secrets_manager_recovery_window_in_days" {
  type        = number
  description = "ASM recovery window for secret shells (0 = force delete; else 7–30)"
  default     = 0
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
  default     = "1.13.1"
  description = "Pinned Karpenter Helm chart version (karpenter-crd and karpenter must match)"
}

variable "karpenter_spot_preferred" {
  type        = bool
  default     = true
  nullable    = false
  description = "Prefer Spot NodePool with On-Demand fallback (aligned with production)"
}

variable "karpenter_node_taints" {
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default     = []
  description = "Taints applied to Karpenter NodePools (hard placement for spot-tolerant workloads)"
}

variable "karpenter_nodepool_weights" {
  type = object({
    spot      = number
    on_demand = number
  })
  default = {
    spot      = 100
    on_demand = 10
  }
  description = "Scheduling preference weights for Karpenter NodePools"
}

variable "karpenter_disruption_budget_nodes" {
  type = object({
    spot      = string
    on_demand = string
  })
  default = {
    spot      = "1"
    on_demand = "1"
  }
  description = <<-EOT
    Per-NodePool voluntary disruption limits (not a global cluster budget).
    Steady state "1"/"1" allows consolidation under WhenEmptyOrUnderutilized.
    Use "0"/"0" only to freeze voluntary disruption during upgrades/migrations.
  EOT
}

variable "karpenter_consolidate_after" {
  type        = string
  default     = "1m"
  nullable    = false
  description = "NodePool disruption consolidateAfter (how long underutilized/empty nodes wait before reclaim)."
}

variable "karpenter_nodepool_cpu_limit" {
  type        = string
  default     = "32"
  description = "NodePool CPU limit to cap spend"
}

variable "karpenter_nodepool_memory_limit" {
  type        = string
  default     = "64Gi"
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

# ──────────────────────────────────────────────
# CloudFront free-tier (storefront ALB origin)
# ──────────────────────────────────────────────

variable "cloudfront_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Create CloudFront distribution in front of the storefront ALB (requires ACM + origin DNS + aliases)"
}

variable "cloudfront_acm_certificate_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "ACM certificate ARN in us-east-1 for CloudFront viewer HTTPS (primary operator input)"
}

variable "cloudfront_origin_domain_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Storefront ALB DNS name (kubectl get ingress frontend-proxy-public … hostname)"
}

variable "cloudfront_aliases" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "CNAMEs covered by the ACM certificate (required when cloudfront_enabled=true)"
}

variable "cloudfront_price_class" {
  type        = string
  default     = "PriceClass_100"
  nullable    = false
  description = "CloudFront price class (PriceClass_100 is free-tier / lowest-cost footprint)"
}

variable "plan_role_arn" {
  type        = string
  default     = null
  description = "IAM Role ARN of the GitHub Actions Plan Role to authorize in EKS"
}

