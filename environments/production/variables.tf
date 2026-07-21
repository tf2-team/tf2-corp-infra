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

variable "immutable_audit_bucket_name" {
  type        = string
  description = "Optional S3 bucket name for the production immutable CloudTrail audit trail. Leave empty to derive from project name and account ID."
  default     = ""
}

variable "immutable_audit_trail_name" {
  type        = string
  description = "Optional CloudTrail name for the production immutable audit trail. Leave empty to derive from project name."
  default     = ""
}

variable "immutable_audit_retention_mode" {
  type        = string
  description = "S3 Object Lock default retention mode for immutable CloudTrail logs."
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.immutable_audit_retention_mode)
    error_message = "immutable_audit_retention_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "immutable_audit_retention_days" {
  type        = number
  description = "S3 Object Lock default retention period in days for immutable CloudTrail logs."
  default     = 90

  validation {
    condition     = var.immutable_audit_retention_days >= 30
    error_message = "immutable_audit_retention_days must be at least 30 days."
  }
}

variable "immutable_audit_cloudwatch_retention_days" {
  type        = number
  description = "CloudWatch Logs retention in days for the dedicated immutable CloudTrail trail."
  default     = 90
}

variable "immutable_audit_alert_email_endpoints" {
  type        = set(string)
  description = "Email endpoints subscribed to Mandate 12.1 immutable audit tamper SNS email-json alerts. Subscribers must confirm the AWS email."
  default     = []
}

variable "immutable_audit_s3_data_event_object_arns" {
  type        = set(string)
  description = "S3 object ARN scopes logged as CloudTrail data events for Mandate 12.2. Use trailing slash for all objects in a bucket, for example arn:aws:s3:::bucket-name/."
  default     = []

  validation {
    condition     = alltrue([for arn in var.immutable_audit_s3_data_event_object_arns : startswith(arn, "arn:aws:s3:::")])
    error_message = "immutable_audit_s3_data_event_object_arns must contain S3 object ARN scopes such as arn:aws:s3:::bucket-name/."
  }
}

variable "immutable_audit_discord_alert_enabled" {
  type        = bool
  description = "Enable Mandate 12.1 Discord alert forwarding through EventBridge, SQS, and Lambda."
  default     = false
}

variable "immutable_audit_discord_webhook_secret_arn" {
  type        = string
  description = "Optional existing Secrets Manager secret ARN containing the Discord webhook URL. Leave empty to create a metadata-only secret shell and bootstrap the value outside Terraform."
  default     = ""
}

variable "immutable_audit_health_check_enabled" {
  type        = bool
  description = "Enable scheduled Mandate 12.1 audit control health checks."
  default     = false
}

variable "immutable_audit_health_check_schedule_expression" {
  type        = string
  description = "EventBridge schedule expression for audit control health checks."
  default     = "rate(15 minutes)"
}

variable "immutable_audit_health_check_max_delivery_age_minutes" {
  type        = number
  description = "Maximum allowed CloudTrail delivery age before the audit health check fails."
  default     = 60
}

variable "immutable_audit_k8s_raw_archive_bucket_name" {
  type        = string
  description = "Optional S3 bucket name for immutable raw EKS audit logs. Leave empty to derive from project name and account ID."
  default     = ""
}

variable "immutable_audit_k8s_raw_archive_retention_mode" {
  type        = string
  description = "S3 Object Lock default retention mode for immutable raw EKS audit logs."
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.immutable_audit_k8s_raw_archive_retention_mode)
    error_message = "immutable_audit_k8s_raw_archive_retention_mode must be GOVERNANCE or COMPLIANCE."
  }
}

variable "immutable_audit_k8s_raw_archive_retention_days" {
  type        = number
  description = "S3 Object Lock default retention period in days for immutable raw EKS audit logs."
  default     = 30

  validation {
    condition     = var.immutable_audit_k8s_raw_archive_retention_days >= 30
    error_message = "immutable_audit_k8s_raw_archive_retention_days must be at least 30 days."
  }
}

variable "immutable_audit_k8s_raw_archive_firehose_log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention in days for Kinesis Data Firehose delivery errors for the raw EKS audit archive."
  default     = 30
}

variable "immutable_audit_k8s_raw_archive_subscription_filter_name" {
  type        = string
  description = "CloudWatch Logs subscription filter name that forwards EKS audit logs to the immutable raw archive Firehose stream."
  default     = "immutable-k8s-audit-raw-archive"
}

variable "immutable_audit_k8s_raw_archive_buffering_size_mb" {
  type        = number
  description = "Kinesis Data Firehose S3 buffering size in MiB for raw EKS audit archive delivery."
  default     = 5
}

variable "immutable_audit_k8s_raw_archive_buffering_interval_seconds" {
  type        = number
  description = "Kinesis Data Firehose S3 buffering interval in seconds for raw EKS audit archive delivery."
  default     = 300
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
  description = "Lifecycle: keep N most recent non-buildcache images per service repo (aligned with development: 5)"
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

variable "enabled_cluster_log_types" {
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
  nullable    = false
  description = "EKS control plane log types exported to CloudWatch (api/audit/authenticator by default)"
}

variable "cluster_log_retention_days" {
  type        = number
  default     = 30
  nullable    = false
  description = "CloudWatch Logs retention days for /aws/eks/<cluster>/cluster (prod: 30)"
}

variable "commerce_valkey_node_type" {
  type        = string
  default     = "cache.t4g.micro"
  description = "Node class for each of the two Multi-AZ cart Valkey nodes."
}

variable "commerce_valkey_engine_version" {
  type        = string
  default     = "8.0"
  description = "ElastiCache Valkey engine version for the cart replication group."
}

variable "commerce_private_dns_zone" {
  type        = string
  default     = "techx.internal"
  description = "Private Route53 zone providing the stable managed Valkey application address."
}

variable "commerce_valkey_snapshot_retention_limit" {
  type        = number
  default     = 7
  description = "Days of automated ElastiCache Valkey snapshots to retain (MANDATE-20; RPO still daily)."
}

variable "backup_protection_attach_role_names" {
  type        = list(string)
  default     = []
  description = "IAM role names that receive the MANDATE-20 deny-destructive-backup policy. Empty creates the policy only (manual attach / console)."
}

variable "rds_postgresql_engine_version" {
  type        = string
  default     = "16"
  description = "Managed PostgreSQL major version."
}

variable "rds_postgresql_instance_class" {
  type        = string
  default     = "db.t4g.small"
  description = "Cost-aware production RDS class."
}

variable "rds_postgresql_database_name" {
  type        = string
  default     = "otel"
  description = "Initial RDS database migrated from the in-cluster PostgreSQL instance."
}

variable "rds_postgresql_allocated_storage" {
  type        = number
  default     = 20
  description = "Initial RDS gp3 storage in GiB."
}

variable "rds_postgresql_max_allocated_storage" {
  type        = number
  default     = 100
  description = "RDS storage autoscaling ceiling in GiB."
}

variable "rds_postgresql_multi_az" {
  type        = bool
  default     = true
  description = "Use a synchronous Multi-AZ standby for revenue and accounting data."
}

variable "rds_postgresql_backup_retention_days" {
  type        = number
  default     = 7
  description = "RDS automated backup and point-in-time recovery retention."
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
  default     = "https://github.com/tmcmanhcuong/techx-corp-chart.git"
  description = "Git URL of the Helm chart repo used by Argo CD Applications"
}

variable "argocd_server_rootpath" {
  type        = string
  default     = "/argocd"
  nullable    = false
  description = <<-EOT
    Path prefix for Argo CD UI (must match frontend-proxy Envoy /argocd route and
    CloudFront blocked prefix). Empty disables path prefix.
  EOT
}

variable "argocd_server_insecure" {
  type        = bool
  default     = true
  nullable    = false
  description = "Serve Argo CD over HTTP (TLS terminates at internal ALB / Envoy)."
}

variable "argocd_server_url" {
  type        = string
  default     = ""
  nullable    = false
  description = <<-EOT
    Optional override for argocd-cm url. Empty + private_dns_enabled derives
    https://<private_dns_zone_name><argocd_server_rootpath>.
  EOT
}

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm-applied)
# ──────────────────────────────────────────────
# Storefront ALB is internal (scheme=internal) with no path-block rules.
# Sensitive-path 403s are enforced at CloudFront (cloudfront_block_sensitive_paths).
# These outputs remain for Helm break-glass helpers (always no ALB blocks).

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
  description = "ASM path prefix for secret shells (e.g. techx-corp/production)"
  default     = "techx-corp/production"
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
  description = "Prefer Spot NodePool with On-Demand fallback (aligned with development)"
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
  default     = ["c", "m", "r", "t"]
  description = "Approved Karpenter Graviton instance categories (production includes burstable t for cost/capacity)."

  validation {
    condition = (
      length(var.karpenter_instance_categories) > 0 &&
      length(var.karpenter_instance_categories) == length(distinct(var.karpenter_instance_categories)) &&
      alltrue([for category in var.karpenter_instance_categories : contains(["c", "m", "r", "t"], category)])
    )
    error_message = "karpenter_instance_categories must be a non-empty, duplicate-free subset of c, m, r, and t."
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

  validation {
    condition = alltrue([
      for budget in [
        var.karpenter_disruption_budget_nodes.spot,
        var.karpenter_disruption_budget_nodes.on_demand,
      ] : contains(["0", "1"], budget)
    ])
    error_message = "Production Karpenter disruption budgets must be absolute node counts of 0 or 1 per pool."
  }
}

variable "karpenter_consolidate_after" {
  type        = string
  default     = "0s"
  nullable    = false
  description = "NodePool disruption consolidateAfter. 0s consolidates empty nodes (DaemonSet-only, e.g. otel agent) immediately; also applies to underutilized packing."
}

variable "karpenter_feature_gates" {
  type        = map(bool)
  default     = {}
  nullable    = false
  description = "Karpenter controller settings.featureGates overrides."

  validation {
    condition = alltrue([
      for k in keys(var.karpenter_feature_gates) :
      contains(["nodeRepair", "nodeOverlay", "reservedCapacity", "spotToSpotConsolidation", "staticCapacity"], k)
    ])
    error_message = "karpenter_feature_gates keys must match supported Karpenter chart featureGates keys."
  }
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
# Cluster Autoscaler (hybrid: system-* MNG only; coexists with Karpenter)
# ──────────────────────────────────────────────

variable "cluster_autoscaler_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Create Cluster Autoscaler IRSA role/policy and tag system-* MNG ASGs for auto-discovery"
}

variable "cluster_autoscaler_install_helm" {
  type        = bool
  default     = false
  nullable    = false
  description = "Install Cluster Autoscaler Helm chart (requires cluster API). Safe with Karpenter: CA owns system MNG ASGs only."
}

variable "cluster_autoscaler_chart_version" {
  type        = string
  default     = "9.46.6"
  description = "Pinned cluster-autoscaler Helm chart version"
}

# ──────────────────────────────────────────────
# CloudFront (internal storefront ALB via VPC origin + path blocking)
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
  default     = true
  nullable    = false
  description = <<-EOT
    When true, CloudFront Function returns HTTP 403 for cloudfront_blocked_prefixes.
    ALB itself has no path-block rules (all traffic from VPC origin forwards to frontend-proxy).
  EOT
}

variable "cloudfront_blocked_prefixes" {
  type = list(string)
  default = [
    "/grafana",
    "/jaeger",
    "/loadgen",
    "/feature",
    "/argocd",
  ]
  nullable    = false
  description = <<-EOT
    URI path prefixes blocked at CloudFront when cloudfront_block_sensitive_paths is true.
    /otlp-http and /flagservice are allowed so the storefront can use browser OTLP and
    flagd evaluation EventStream via the public edge. /argocd is VPN/private-DNS only.
  EOT
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
  default     = "10.100.0.0/22"
  nullable    = false
  description = "IPv4 CIDR for VPN clients (must not overlap VPC CIDR 10.0.0.0/16)"
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

# ──────────────────────────────────────────────
# Private DNS — internal.<domain>/<service> for Client VPN operators
# ──────────────────────────────────────────────

variable "private_dns_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = <<-EOT
    When true, create a Route 53 private hosted zone associated with the VPC and
    an apex Alias A to the internal storefront ALB (e.g. internal.hungtran.id.vn).
    Services are path-based on frontend-proxy. Resolvable from Client VPN
    (AmazonProvidedDNS). See docs/client-vpn.md.
  EOT
}

variable "private_dns_zone_name" {
  type        = string
  default     = "internal.hungtran.id.vn"
  nullable    = false
  description = "Private hosted zone apex / operator hostname (e.g. internal.hungtran.id.vn)"
}

variable "private_dns_service_paths" {
  type = map(string)
  default = {
    grafana     = "/grafana/"
    jaeger      = "/jaeger/"
    loadgen     = "/loadgen/"
    feature     = "/feature/"
    argocd      = "/argocd/"
    flagservice = "/flagservice/"
  }
  nullable    = false
  description = "Service short name → URL path (documentation/outputs; DNS is a single apex record)"
}

variable "private_dns_acm_certificate_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = <<-EOT
    Existing ACM certificate ARN covering private_dns_zone_name (us-east-1 / ALB region).
    Same pattern as cloudfront_acm_certificate_arn: issue the cert outside Terraform,
    then set this ARN. Also set chart publicAlb.certificateArn to the same value.
  EOT
}

variable "private_dns_use_https_urls" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, force https:// in outputs even if acm_certificate_arn is empty (not recommended)"
}

variable "access_entries" {
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    policy_arn        = optional(string)
  }))
  default     = {}
  description = "Bản đồ các EKS Access Entries bổ sung cần cấu hình"
}

# ──────────────────────────────────────────────
# Cost budgets — onboarding ~$300/week as monthly $900 (no WEEKLY API)
# ──────────────────────────────────────────────

variable "cost_budgets_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create SNS (email-json) + monthly/daily AWS Budgets for the TF spend ceiling"
}

variable "cost_budgets_alert_email" {
  type        = string
  default     = ""
  nullable    = false
  description = "Email for cost budget SNS email-json alerts (required when cost_budgets_enabled=true; Confirm after apply)"
}

variable "cost_budgets_monthly_limit_usd" {
  type        = string
  default     = "900"
  nullable    = false
  description = "Monthly COST budget USD (≈ $300/week × 3 capstone weeks; AWS has no WEEKLY time_unit)"
}

variable "cost_budgets_daily_limit_usd" {
  type        = string
  default     = "45"
  nullable    = false
  description = "Daily COST budget limit in USD (early warning ≈ weekly/7)"
}

variable "cost_budgets_create_daily" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, also create the daily budget"
}

variable "cost_budget_actions_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create manual Budget Actions that attach a deny scale-out policy to the Karpenter controller role"
}

variable "cost_budget_action_monthly_threshold_percentage" {
  type        = number
  default     = 100
  nullable    = false
  description = "Manual Budget Action threshold for the monthly budget"
}

variable "cost_budget_action_daily_threshold_percentage" {
  type        = number
  default     = 100
  nullable    = false
  description = "Manual Budget Action threshold for the daily budget"
}

variable "cost_budget_daily_action_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "Keep false because AWS Budgets Actions do not support DAILY budgets"
}

# ──────────────────────────────────────────────
# Cost Anomaly Detection — account-level; production only
# ──────────────────────────────────────────────

variable "cost_anomaly_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create Cost Explorer anomaly monitor + email subscription"
}

variable "cost_anomaly_alert_email" {
  type        = string
  default     = ""
  nullable    = false
  description = "Email for Cost Anomaly alerts (required when cost_anomaly_enabled=true; Confirm if AWS asks)"
}

variable "cost_anomaly_frequency" {
  type        = string
  default     = "DAILY"
  nullable    = false
  description = "Anomaly notification frequency: DAILY | IMMEDIATE | WEEKLY"
}

variable "cost_anomaly_impact_absolute_usd" {
  type        = string
  default     = "25"
  nullable    = false
  description = "Alert when anomaly impact >= this USD (AND with percentage)"
}

variable "cost_anomaly_impact_percentage" {
  type        = string
  default     = "40"
  nullable    = false
  description = "Alert when anomaly impact >= this percent vs expected (AND with absolute USD)"
}

# ──────────────────────────────────────────────
# Amazon MSK Configuration (Directive #8)
# ──────────────────────────────────────────────

variable "msk_kafka_version" {
  type        = string
  default     = "3.7.x"
  description = "Apache Kafka version for the MSK cluster"
}

variable "msk_broker_instance_type" {
  type        = string
  default     = "kafka.t3.small"
  description = "EC2 instance type for the MSK brokers"
}

variable "msk_ebs_volume_size" {
  type        = number
  default     = 10
  description = "EBS volume size in GiB for each broker node"
}

# ──────────────────────────────────────────────
# P3 CUR + Athena + Grafana IRSA — production only
# ──────────────────────────────────────────────

variable "cur_athena_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, create Athena/Glue/IRSA resources for the existing production CUR 2.0 export"
}

variable "cur_athena_region" {
  type        = string
  default     = "ap-southeast-1"
  nullable    = false
  description = "Region of the existing CUR S3 bucket and Athena catalog/workgroup"
}

variable "cur_athena_cur_bucket_name" {
  type        = string
  default     = "company-cdo-493499579600-telemetry"
  nullable    = false
  description = "Existing S3 bucket containing the CUR 2.0 Data Export"
}

variable "cur_athena_cur_s3_prefix" {
  type        = string
  default     = "cur"
  nullable    = false
  description = "Existing CUR export S3 prefix"
}

variable "cur_athena_cur_export_name" {
  type        = string
  default     = "finops-watch-cur"
  nullable    = false
  description = "Existing CUR 2.0 Data Export name"
}

variable "cur_athena_database_name" {
  type        = string
  default     = "finops_cur"
  nullable    = false
  description = "Glue database for CUR Athena queries"
}

variable "cur_athena_crawler_name" {
  type        = string
  default     = "techx-prod-tf2-cur-athena"
  nullable    = false
  description = "Glue crawler for existing CUR export"
}

variable "cur_athena_workgroup_name" {
  type        = string
  default     = "grafana-cur"
  nullable    = false
  description = "Athena workgroup for Grafana CUR queries"
}

variable "cur_athena_results_bucket_name" {
  type        = string
  default     = "techx-prod-tf2-athena-results-493499579600-ap-southeast-1"
  nullable    = false
  description = "S3 bucket for Grafana/Athena query results"
}

variable "cur_athena_bytes_cutoff" {
  type        = number
  default     = 1073741824
  nullable    = false
  description = "Per-query bytes scanned cutoff for Grafana CUR workgroup"
}

variable "cur_athena_grafana_namespace" {
  type        = string
  default     = "techx-corp-prod"
  nullable    = false
  description = "Namespace of the Grafana service account"
}

variable "cur_athena_grafana_service_account_name" {
  type        = string
  default     = "grafana"
  nullable    = false
  description = "Grafana service account name for IRSA trust"
}

# ──────────────────────────────────────────────
# Overlay anomaly routing — email first
# ──────────────────────────────────────────────

variable "cost_anomaly_routing_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, route high-impact Cost Anomaly events through AWS User Notifications email"
}

variable "cost_anomaly_routing_email" {
  type        = string
  default     = "ctran13904@gmail.com"
  nullable    = false
  description = "Email contact for routed Cost Anomaly events"
}

variable "cost_anomaly_routing_regions" {
  type        = set(string)
  default     = ["us-east-1"]
  nullable    = false
  description = "Regions where User Notifications watches Cost Explorer anomaly events"
}

variable "cost_anomaly_routing_hub_region" {
  type        = string
  default     = "us-east-1"
  nullable    = false
  description = "AWS User Notifications hub region"
}

variable "cost_anomaly_routing_impact_absolute_usd" {
  type        = number
  default     = 25
  nullable    = false
  description = "Route only anomalies whose impact is greater than this USD amount"
}

variable "cost_anomaly_routing_aggregation_duration" {
  type        = string
  default     = "SHORT"
  nullable    = false
  description = "AWS User Notifications aggregation duration: NONE, SHORT, or LONG"
}

# ──────────────────────────────────────────────
# Mandate 05 runtime security alerting
# ──────────────────────────────────────────────

variable "runtime_security_alerting_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create SNS + Lambda classifier for Mandate 05 runtime-hardening admission-deny alerts."
}

variable "runtime_security_audit_log_group_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional EKS audit log group override. Empty derives /aws/eks/<cluster>/cluster."
}

variable "runtime_security_alert_email" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional email-json endpoint for runtime security SNS alerts; confirm subscription after apply."
}

variable "runtime_security_enable_guardduty_eventbridge" {
  type        = bool
  default     = false
  nullable    = false
  description = "Route existing GuardDuty High/Critical findings to runtime security SNS. Does not enable GuardDuty Runtime Monitoring."
}

variable "runtime_security_enable_node_role_anomaly_events" {
  type        = bool
  default     = false
  nullable    = false
  description = "Route selected worker-node role CloudTrail events after baseline approval."
}

# ──────────────────────────────────────────────
# Overlay Cost Optimization Hub backlog — production only
# ──────────────────────────────────────────────

# ------------------------------------------------------------------------------
# Mandate 11.2 audit detection pipeline
# ------------------------------------------------------------------------------

variable "audit_detection_pipeline_enabled" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create Mandate 11.2 EventBridge and EKS audit log filters that forward raw events to the Task 11.3 parser Lambda."
}

variable "audit_detection_lambda_function_name" {
  type        = string
  default     = "techx-audit-alert-parser"
  nullable    = false
  description = "Lambda function name for the Task 11.3 audit alert parser."
}

variable "audit_detection_lambda_role_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional IAM role name override for the Mandate 11 parser Lambda."
}

variable "audit_detection_lambda_policy_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional inline IAM policy name override for the Mandate 11 parser Lambda role."
}

variable "audit_detection_dlq_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional SQS DLQ name override for failed Mandate 11 parser events."
}

variable "audit_detection_lambda_kms_key_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional KMS key ARN for the Mandate 11 parser Lambda and DLQ."
}

variable "audit_detection_lambda_tracing_mode" {
  type        = string
  default     = "PassThrough"
  nullable    = false
  description = "Lambda tracing mode for Mandate 11 parser. Use Active only after X-Ray cost and sampling are approved."
}

variable "audit_detection_cloudtrail_event_rule_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional EventBridge rule name override for Mandate 11 CloudTrail high-risk candidates."
}

variable "audit_detection_cloudtrail_event_target_id" {
  type        = string
  default     = "audit-alert-parser-direct"
  nullable    = false
  description = "EventBridge target ID for direct CloudTrail to parser Lambda delivery."
}

variable "audit_detection_audit_log_group_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional EKS audit log group override for Mandate 11.2. Empty derives /aws/eks/<cluster>/cluster."
}

variable "audit_detection_eks_audit_subscription_filter_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional CloudWatch Logs subscription filter name override for Mandate 11 EKS audit candidates."
}

variable "audit_detection_eks_audit_filter_pattern" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional CloudWatch Logs subscription filter override for Mandate 11.2 EKS audit candidates. Empty uses module default."
}

variable "audit_detection_lambda_reserved_concurrent_executions" {
  type        = number
  default     = null
  nullable    = true
  description = "Optional reserved concurrency for the Mandate 11 parser Lambda. Null omits the setting."
}

variable "audit_detection_alarm_action_arns" {
  type        = list(string)
  default     = []
  nullable    = false
  description = "Optional SNS or incident-management ARNs for Mandate 11.2 CloudWatch alarms."
}

variable "audit_detection_enable_discord_router" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create the Mandate 11.4 SQS-to-Discord router and wire parser alert-ready output to it."
}

variable "audit_detection_alert_ready_queue_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional SQS queue name for Mandate 11.4 alert-ready payloads."
}

variable "audit_detection_alert_ready_dlq_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional SQS DLQ name for Mandate 11.4 alert-ready payloads."
}

variable "audit_detection_router_lambda_function_name" {
  type        = string
  default     = "techx-audit-alert-router"
  nullable    = false
  description = "Lambda function name for the Mandate 11.4 Discord router."
}

variable "audit_detection_router_lambda_role_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional IAM role name for the Mandate 11.4 Discord router Lambda."
}

variable "audit_detection_router_lambda_policy_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional IAM inline policy name for the Mandate 11.4 Discord router Lambda."
}

variable "audit_detection_discord_webhook_secret_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional Secrets Manager name for the Mandate 11 Discord webhook URL."
}

variable "audit_detection_discord_webhook_secret_arn" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional existing Secrets Manager ARN for the Mandate 11 Discord webhook URL."
}

variable "audit_detection_ttd_threshold_seconds" {
  type        = number
  default     = 300
  nullable    = false
  description = "Mandate 11.5 end-to-end TTD alarm threshold in seconds."
}

variable "audit_detection_ttd_dashboard_name" {
  type        = string
  default     = ""
  nullable    = false
  description = "Optional CloudWatch dashboard name for Mandate 11.5 TTD evidence."
}

variable "cost_optimization_backlog_enabled" {
  type        = bool
  default     = true
  nullable    = false
  description = "When true, enable Cost Optimization Hub and export recommendations to S3"
}

variable "cost_optimization_backlog_bucket_name" {
  type        = string
  default     = "techx-prod-tf2-cost-optimization-exports-493499579600-us-east-1"
  nullable    = false
  description = "Dedicated S3 bucket for Cost Optimization Hub recommendation exports"
}

variable "cost_optimization_backlog_s3_prefix" {
  type        = string
  default     = "cost-optimization"
  nullable    = false
  description = "S3 prefix for Cost Optimization Hub recommendation export"
}

variable "cost_optimization_backlog_export_name" {
  type        = string
  default     = "cost-optimization-recommendations"
  nullable    = false
  description = "BCM Data Exports export name for recommendations"
}

variable "cost_optimization_backlog_create_export" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, create the Cost Optimization Hub BCM Data Export. Keep false until this account can create exports against COST_OPTIMIZATION_RECOMMENDATIONS."
}

variable "cost_optimization_backlog_database_name" {
  type        = string
  default     = "finops_cost_optimization"
  nullable    = false
  description = "Glue database for Cost Optimization Hub recommendation export"
}

variable "cost_optimization_backlog_crawler_name" {
  type        = string
  default     = "techx-prod-tf2-cost-optimization-backlog"
  nullable    = false
  description = "Glue crawler for Cost Optimization Hub recommendation export"
}

variable "cost_optimization_backlog_workgroup_name" {
  type        = string
  default     = "cost-optimization-backlog"
  nullable    = false
  description = "Athena workgroup for Cost Optimization Hub backlog queries"
}

variable "cost_optimization_backlog_athena_bytes_cutoff" {
  type        = number
  default     = 1073741824
  nullable    = false
  description = "Per-query bytes scanned cutoff for Cost Optimization Hub backlog workgroup"
}

variable "cost_optimization_backlog_include_member_accounts" {
  type        = bool
  default     = false
  nullable    = false
  description = "Enroll organization member accounts if this is the management account"
}

variable "cost_optimization_backlog_manage_enrollment" {
  type        = bool
  default     = false
  nullable    = false
  description = "When true, Terraform manages Cost Optimization Hub enrollment; false when enrollment is handled manually in the console"
}

variable "cost_optimization_backlog_include_all_recommendations" {
  type        = bool
  default     = false
  nullable    = false
  description = "Export all recommendations for a resource rather than the de-duplicated recommendation"
}

# Mem0 managed PostgreSQL

variable "mem0_postgresql_engine_version" {
  type        = string
  default     = "17"
  description = "RDS PostgreSQL engine version for Mem0"
}

variable "mem0_postgresql_instance_class" {
  type        = string
  default     = "db.t4g.small"
  description = "RDS instance class for Mem0"
}

variable "mem0_postgresql_allocated_storage" {
  type        = number
  default     = 50
  description = "Initial Mem0 RDS gp3 storage in GiB"
}

variable "mem0_postgresql_max_allocated_storage" {
  type        = number
  default     = 200
  description = "Mem0 RDS storage autoscaling limit in GiB"
}

variable "mem0_postgresql_multi_az" {
  type        = bool
  default     = false
  description = "Enable a Multi-AZ standby for Mem0 RDS; disabled for the current single-AZ cost profile"
}

variable "mem0_postgresql_iam_database_authentication_enabled" {
  type        = bool
  default     = true
  description = "Enable IAM database authentication for the Mem0 workload"
}

variable "mem0_postgresql_iam_database_user" {
  type        = string
  default     = "mem0_app"
  description = "PostgreSQL application user that the Mem0 IRSA role may connect as"
}

variable "mem0_postgresql_backup_retention_period" {
  type        = number
  default     = 14
  description = "Mem0 RDS automated backup retention in days"
}

variable "mem0_postgresql_deletion_protection" {
  type        = bool
  default     = true
  description = "Protect production Mem0 RDS from deletion"
}

variable "mem0_postgresql_skip_final_snapshot" {
  type        = bool
  default     = false
  description = "Whether production destroy may skip the final RDS snapshot"
}

variable "mem0_postgresql_performance_insights_enabled" {
  type        = bool
  default     = true
  description = "Enable Performance Insights for Mem0 RDS"
}

variable "mem0_postgresql_kms_key_id" {
  type        = string
  default     = null
  description = "Optional customer-managed KMS key for Mem0 RDS"
}

# Change trail: @hungxqt - 2026-07-20 - Add MANDATE-20 Valkey snapshot retention and backup-protection vars.
