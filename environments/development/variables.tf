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
    cidr_block                 = string
    availability_zone          = string
    nat_gateway_key            = optional(string)
    enable_karpenter_discovery = optional(bool, true)
    enable_eks_internal_elb    = optional(bool, true)
  }))
  default     = {}
  description = "Private subnets. Prefer /20+ for node/pod IPs under VPC CNI prefix delegation; set enable_karpenter_discovery=false on legacy small CIDRs after migration."
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

variable "argocd_server_rootpath" {
  type        = string
  default     = "/argocd"
  nullable    = false
  description = "Path prefix for Argo CD UI (must match frontend-proxy Envoy /argocd route)."
}

variable "argocd_server_insecure" {
  type        = bool
  default     = true
  nullable    = false
  description = "Serve Argo CD over HTTP (TLS terminates at ALB / Envoy when path-exposed)."
}

variable "argocd_server_url" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional argocd-cm url override (empty = unset; use port-forward in dev)."
}

# ──────────────────────────────────────────────
# Storefront ALB (internal; no path blocks — blocking is on CloudFront)
# ──────────────────────────────────────────────
# Path rules are enforced by techx-corp-chart Ingress annotations (ALB Controller),
# not by raw AWS Terraform resources. These variables are the IaC source of truth
# for operators / deploy scripts.

variable "storefront_alb_scheme" {
  type        = string
  default     = "internal"
  nullable    = false
  description = "ALB scheme for frontend-proxy-public Ingress (must be internal when using CloudFront VPC origin)"

  validation {
    condition     = contains(["internal", "internet-facing"], var.storefront_alb_scheme)
    error_message = "storefront_alb_scheme must be internal or internet-facing."
  }
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

variable "karpenter_ami_alias" {
  type        = string
  default     = "al2023@v20260709"
  description = "Pinned AL2023 alias for Karpenter EC2NodeClass."

  validation {
    condition     = can(regex("^al2023@v[0-9]{8}$", var.karpenter_ami_alias))
    error_message = "karpenter_ami_alias must be pinned as al2023@vYYYYMMDD."
  }
}

variable "karpenter_instance_categories" {
  type        = list(string)
  default     = ["c", "m", "r"]
  description = "Approved Karpenter Graviton instance categories."

  validation {
    condition = (
      length(var.karpenter_instance_categories) > 0 &&
      length(var.karpenter_instance_categories) == length(distinct(var.karpenter_instance_categories)) &&
      alltrue([for category in var.karpenter_instance_categories : contains(["c", "m", "r"], category)])
    )
    error_message = "karpenter_instance_categories must be a non-empty, duplicate-free subset of c, m, and r."
  }
}

variable "karpenter_expire_after" {
  type        = string
  default     = "720h"
  description = "Karpenter NodePool expiry duration."

  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h)$", var.karpenter_expire_after))
    error_message = "karpenter_expire_after must be a positive duration using s, m, or h."
  }
}

variable "karpenter_termination_grace_period" {
  type        = string
  default     = "1h"
  description = "Maximum Karpenter graceful drain duration before forced termination."

  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h)$", var.karpenter_termination_grace_period))
    error_message = "karpenter_termination_grace_period must be a positive duration using s, m, or h."
  }
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
  default     = "0s"
  nullable    = false
  description = "NodePool disruption consolidateAfter. 0s consolidates empty nodes (DaemonSet-only, e.g. otel agent) immediately; also applies to underutilized packing."
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
  description = "Create CloudFront distribution with VPC origin to the internal storefront ALB"
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
  description = "Internal storefront ALB DNS name (kubectl get ingress frontend-proxy-public … hostname)"
}

variable "cloudfront_origin_alb_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = <<-EOT
    Internal storefront ALB ARN for CloudFront VPC origin (required when cloudfront_enabled=true).
    Example:
      aws elbv2 describe-load-balancers --region us-east-1 ^
        --query "LoadBalancers[?DNSName=='<alb-dns>'].LoadBalancerArn" --output text
  EOT
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

variable "cloudfront_block_sensitive_paths" {
  type        = bool
  default     = false
  nullable    = false
  description = <<-EOT
    When true, CloudFront Function returns HTTP 403 for cloudfront_blocked_prefixes.
    Default false in development for open demo access via the edge.
  EOT
}

variable "cloudfront_blocked_prefixes" {
  type = list(string)
  default = [
    "/grafana",
    "/jaeger",
    "/loadgen",
    "/feature",
    "/flagservice",
    "/otlp-http",
    "/argocd",
  ]
  nullable    = false
  description = "URI path prefixes blocked at CloudFront when cloudfront_block_sensitive_paths is true"
}

variable "cloudfront_web_acl_id" {
  type        = string
  default     = null
  description = <<-EOT
    WAFv2 web ACL ARN for the storefront CloudFront distribution (global / us-east-1).
    Required when the distribution is on a CloudFront flat-rate pricing plan: leave the
    plan-created ACL attached so UpdateDistribution does not clear web_acl_id.
    Discover with:
      aws cloudfront get-distribution --id <DISTRIBUTION_ID> ^
        --query Distribution.DistributionConfig.WebACLId --output text
  EOT
}

variable "plan_role_arn" {
  type        = string
  default     = null
  description = "IAM Role ARN of the GitHub Actions Plan Role to authorize in EKS"
}

# ──────────────────────────────────────────────
# Client VPN — private operator access to internal ALB
# ──────────────────────────────────────────────

variable "client_vpn_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = <<-EOT
    When true, create AWS Client VPN for private access to the internal storefront
    ALB and the EKS private Kubernetes API (cluster SG TCP 443 from client CIDR).
    Public EKS endpoint access is unchanged (dual access when public is enabled).
  EOT
}

variable "client_vpn_client_cidr_block" {
  type        = string
  default     = "10.101.0.0/22"
  nullable    = false
  description = "IPv4 CIDR for VPN clients (must not overlap VPC CIDR 10.1.0.0/16)"
}

variable "client_vpn_server_certificate_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "ACM server certificate ARN for Client VPN (same region as VPC; required when enabled)"
}

variable "client_vpn_client_ca_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "ACM ARN of the client CA certificate used for mutual TLS (required when enabled)"
}

variable "client_vpn_subnet_ids" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Private subnet IDs to associate (empty = first private subnet only, for cost control)"
}

variable "client_vpn_split_tunnel" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, only VPC-destined traffic uses the VPN"
}

variable "client_vpn_alb_security_group_ids" {
  type        = list(string)
  default     = []
  nullable    = false
  description = <<-EOT
    Optional internal storefront ALB security group IDs. When set, Terraform adds
    ingress TCP 80 from client_vpn_client_cidr_block so VPN clients can reach the ALB.
    Discover with: aws elbv2 describe-load-balancers / describe-security-groups.
    Do not take exclusive SG ownership via Ingress annotations (CloudFront VPC origin).
  EOT
}
# Change trail: @hungxqt - 2026-07-15 - Default karpenter_consolidate_after to 0s for immediate empty reclaim.

# Mem0 managed PostgreSQL

variable "mem0_postgresql_engine_version" {
  type        = string
  default     = "17"
  description = "RDS PostgreSQL engine version for Mem0"
}

variable "mem0_postgresql_instance_class" {
  type        = string
  default     = "db.t4g.micro"
  description = "RDS instance class for Mem0"
}

variable "mem0_postgresql_allocated_storage" {
  type        = number
  default     = 20
  description = "Initial Mem0 RDS gp3 storage in GiB"
}

variable "mem0_postgresql_max_allocated_storage" {
  type        = number
  default     = 100
  description = "Mem0 RDS storage autoscaling limit in GiB"
}

variable "mem0_postgresql_multi_az" {
  type        = bool
  default     = false
  description = "Enable a Multi-AZ standby for Mem0 RDS"
}

variable "mem0_postgresql_backup_retention_period" {
  type        = number
  default     = 7
  description = "Mem0 RDS automated backup retention in days"
}

variable "mem0_postgresql_deletion_protection" {
  type        = bool
  default     = false
  description = "Protect Mem0 RDS from deletion"
}

variable "mem0_postgresql_skip_final_snapshot" {
  type        = bool
  default     = true
  description = "Skip a final snapshot when destroying development Mem0 RDS"
}

variable "mem0_postgresql_performance_insights_enabled" {
  type        = bool
  default     = false
  description = "Enable Performance Insights for Mem0 RDS"
}

variable "mem0_postgresql_kms_key_id" {
  type        = string
  default     = null
  description = "Optional customer-managed KMS key for Mem0 RDS"
}
