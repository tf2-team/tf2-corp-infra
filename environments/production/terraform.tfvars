aws_region   = "us-east-1"
project_name = "techx-prod-tf2"

tags = {
  Environment = "production"
  Owner       = "CDO-03-06"
  Project     = "techx-platform"
}

# Image format: REGISTRY/techx-prod-corp/SERVICE:VERSION
# Module creates one nested ECR repo per platform service (default catalog).
# Lifecycle matches development (keep last 5 images + 1 buildcache).
ecr_project_name           = "techx-prod-corp"
ecr_naming_mode            = "nested"
ecr_image_tag_mutability   = "IMMUTABLE"
ecr_keep_last_n_images     = 5
ecr_keep_last_n_buildcache = 1
ecr_scan_on_push           = false
ecr_force_delete           = true

# ──────────────────────────────────────────────
# VPC Configuration
# Non-overlapping CIDR with development (10.1.0.0/16)
# Node/pod capacity lives on /20 priv-*-nodes (prefix-delegation needs free /28s).
# Legacy /24 priv-1a/1b stay for gradual drain; Karpenter discovery disabled on them.
# ──────────────────────────────────────────────
vpc_cidr_block = "10.0.0.0/16"

public_subnets = {
  "pub-1a" = {
    cidr_block        = "10.0.1.0/24"
    availability_zone = "us-east-1a"
  }
  "pub-1b" = {
    cidr_block        = "10.0.2.0/24"
    availability_zone = "us-east-1b"
  }
}

private_subnets = {
  # Legacy small CIDRs — keep for existing ENIs/ALB during migration; no new Karpenter nodes.
  "priv-1a" = {
    cidr_block                 = "10.0.10.0/24"
    availability_zone          = "us-east-1a"
    nat_gateway_key            = "nat-1a"
    enable_karpenter_discovery = false
  }
  "priv-1b" = {
    cidr_block                 = "10.0.11.0/24"
    availability_zone          = "us-east-1b"
    nat_gateway_key            = "nat-1a"
    enable_karpenter_discovery = false
  }
  # Primary node/pod subnets (~4k IPs each; ~256× /28 prefixes per AZ).
  "priv-1a-nodes" = {
    cidr_block        = "10.0.16.0/20"
    availability_zone = "us-east-1a"
    nat_gateway_key   = "nat-1a"
  }
  "priv-1b-nodes" = {
    cidr_block        = "10.0.32.0/20"
    availability_zone = "us-east-1b"
    nat_gateway_key   = "nat-1a"
  }
}

nat_gateways = {
  "nat-1a" = {
    public_subnet_key = "pub-1a"
  }
}

# ──────────────────────────────────────────────
# EKS Configuration (aligned with development topology)
# Critical floor only: system-* MNG (ARM On-Demand, workload-class=critical).
# No legacy general-* dual-run capacity — same model as development.
# Phase 1 has no Cluster Autoscaler; max_size is an emergency ceiling only.
# One managed node group per AZ so EBS volumes / pods can schedule in both zones.
# ──────────────────────────────────────────────
cluster_name       = "techx-tf2-prod"
kubernetes_version = "1.36"

# Directive #3 managed stateful dependencies. Two small Valkey nodes span the
# private subnets/AZs; DynamoDB outbox is on-demand and has no idle capacity fee.
commerce_valkey_node_type      = "cache.t4g.micro"
commerce_valkey_engine_version = "8.0"
commerce_private_dns_zone      = "techx.internal"

# Directive #8 managed PostgreSQL. Multi-AZ protects the revenue/accounting
# path; t4g.small and gp3 are the right-sized production starting point.
rds_postgresql_engine_version        = "16"
rds_postgresql_instance_class        = "db.t4g.small"
rds_postgresql_database_name         = "otel"
rds_postgresql_allocated_storage     = 20
rds_postgresql_max_allocated_storage = 100
rds_postgresql_multi_az              = true
rds_postgresql_backup_retention_days = 7

node_groups = {
  "system-1a" = {
    instance_types = ["t4g.large"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_ARM_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    max_pods       = 110
    subnet_keys    = ["priv-1a-nodes"]
    labels = {
      role           = "critical"
      workload-class = "critical"
      env            = "production"
      az             = "us-east-1a"
    }
  }
  "system-1b" = {
    instance_types = ["t4g.large"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_ARM_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    max_pods       = 110
    subnet_keys    = ["priv-1b-nodes"]
    labels = {
      role           = "critical"
      workload-class = "critical"
      env            = "production"
      az             = "us-east-1b"
    }
  }
}

addons = {
  "vpc-cni" = {
    addon_version = "v1.22.3-eksbuild.1"
    # ENABLE_PREFIX_DELEGATION raises IP density; pair with node max_pods / Karpenter node_max_pods
    # Raw JSON string (jsonencode is not allowed in .tfvars)
    configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\",\"WARM_PREFIX_TARGET\":\"1\"},\"resources\":{\"requests\":{\"memory\":\"64Mi\"},\"limits\":{\"cpu\":\"250m\",\"memory\":\"256Mi\"}},\"init\":{\"resources\":{\"requests\":{\"memory\":\"32Mi\"},\"limits\":{\"cpu\":\"100m\",\"memory\":\"128Mi\"}}},\"nodeAgent\":{\"resources\":{\"requests\":{\"memory\":\"32Mi\"},\"limits\":{\"cpu\":\"100m\",\"memory\":\"128Mi\"}}}}"
  }
  "coredns" = {
    addon_version = "v1.14.3-eksbuild.3"
    # Pin CoreDNS to critical MNG (schema supports nodeSelector for this addon version).
    configuration_values = "{\"nodeSelector\":{\"workload-class\":\"critical\"},\"resources\":{\"limits\":{\"cpu\":\"200m\"}}}"
  }
  "kube-proxy" = {
    addon_version        = "v1.36.0-eksbuild.9"
    configuration_values = "{\"resources\":{\"requests\":{\"memory\":\"64Mi\"},\"limits\":{\"cpu\":\"250m\",\"memory\":\"256Mi\"}}}"
  }
  "aws-ebs-csi-driver" = {
    # Pin controller only; ebs-csi-node DaemonSet stays universal (no workload-class selector).
    configuration_values = "{\"controller\":{\"nodeSelector\":{\"workload-class\":\"critical\"},\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"node\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"sidecars\":{\"attacher\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"livenessProbe\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"nodeDriverRegistrar\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"provisioner\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"resizer\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}},\"snapshotter\":{\"resources\":{\"limits\":{\"cpu\":\"100m\"}}}}}"
  }
}

# ──────────────────────────────────────────────
# Argo CD (REL-09) — same enablement model as development
# Requires: aws eks update-kubeconfig + cluster API reachable during apply
# ──────────────────────────────────────────────
argocd_enabled       = true
argocd_chart_version = "7.8.28"
# Override if chart lives under a different GitHub path:
argocd_chart_repo_url = "https://github.com/tf2-team/tf2-corp-chart/tree/main"

# Storefront ALB is internal (chart values-public-alb.yaml); no ALB path blocks.
# Path blocking is at CloudFront (cloudfront_block_sensitive_paths below).
storefront_alb_scheme = "internal"

# Force-delete secret shells (same as development) for faster tear-down / re-bootstrap
secrets_manager_recovery_window_in_days = 0

# ──────────────────────────────────────────────
# Karpenter (node autoscaling) — Spot preferred (same as development)
# Requires: cluster API reachable when install_helm / create_node_resources are true
# Default capacity model: critical MNG floor + Karpenter elastic (do not enable CA Helm with this).
# CRD and controller must share chart_version; upgrade CRD before controller.
# ──────────────────────────────────────────────
karpenter_enabled                  = true
karpenter_install_helm             = true
karpenter_create_node_resources    = true
karpenter_chart_version            = "1.13.1"
karpenter_spot_preferred           = true
karpenter_ami_alias                = "al2023@v20260709"
karpenter_instance_categories      = ["c", "m", "r", "t"]
karpenter_expire_after             = "720h"
karpenter_termination_grace_period = "1h"
karpenter_nodepool_cpu_limit       = "32"
karpenter_nodepool_memory_limit    = "64Gi"
karpenter_availability_zones       = ["us-east-1a", "us-east-1b"]
# Match MNG density + avoid 1-vCPU nodes (~8 max pods, no room for DaemonSets)
karpenter_node_max_pods    = 110
karpenter_min_instance_cpu = 2
# Hard placement contract for classified stateless apps
karpenter_node_taints = [
  {
    key    = "workload-class"
    value  = "spot-tolerant"
    effect = "NoSchedule"
  }
]
karpenter_nodepool_weights = {
  spot      = 100
  on_demand = 10
}
# Steady state: one voluntary disruption per NodePool so consolidation can reclaim idle capacity.
# Freeze to "0"/"0" only during multi-minor Karpenter upgrades or placement migrations.
karpenter_disruption_budget_nodes = {
  spot      = "1"
  on_demand = "1"
}
# Immediate reclaim once a node is empty or underutilized (WhenEmptyOrUnderutilized).
# DaemonSet-only nodes (otel-collector agent, aws-node, kube-proxy, ebs-csi, …) are empty
# and consolidate without a settle delay; underutilized packing is also eligible at 0s.
karpenter_consolidate_after = "0s"
# Allow Karpenter to replace fragmented Spot capacity with better-packed Spot capacity.
karpenter_feature_gates = {
  spotToSpotConsolidation = true
}

# ──────────────────────────────────────────────
# Cluster Autoscaler — OFF by default
# Scales managed node group ASGs only (within min_size/max_size).
# For CA-only experiments: disable Karpenter install/NodePools first, then enable CA.
# See docs/cluster-autoscaler.md
# ──────────────────────────────────────────────
cluster_autoscaler_enabled       = false
cluster_autoscaler_install_helm  = false
cluster_autoscaler_chart_version = "9.46.6"

# ──────────────────────────────────────────────
# CloudFront — internal ALB via VPC origin + edge path blocking
# Prerequisites: internal ALB healthy; ACM cert ISSUED in us-east-1; ALB ARN set.
# After chart scheme→internal, ALB DNS/ARN change — update origin_* then apply.
# See docs/cloudfront.md
# ──────────────────────────────────────────────
cloudfront_enabled             = true
cloudfront_acm_certificate_arn = "arn:aws:acm:us-east-1:493499579600:certificate/d21f8de5-4a2b-43ae-b3d8-78f0c43957f9"
cloudfront_origin_domain_name  = "k8s-techxcor-frontend-7248b316f5-455614012.us-east-1.elb.amazonaws.com"
# REQUIRED for VPC origin — set after internal ALB exists (replace placeholder):
cloudfront_origin_alb_arn = "arn:aws:elasticloadbalancing:us-east-1:493499579600:loadbalancer/app/k8s-techxcor-frontend-ae4ef3a99c/67565bb9a2abe1fb"
cloudfront_aliases        = ["shop.hungtran.id.vn"]
# Matches live distribution (PAYG after flat-rate plan cancel). Tighten to PriceClass_100 later if desired.
cloudfront_price_class           = "PriceClass_All"
cloudfront_block_sensitive_paths = true
# PAYG: no WAF. Flat-rate plan was cancelled; leave unset so apply detaches CreatedByCloudFront-* ACL.
# To attach your own WAFv2 later: set cloudfront_web_acl_id to a global web ACL ARN.
# cloudfront_web_acl_id = null

# ──────────────────────────────────────────────
# Client VPN — private admin access to internal storefront ALB
# Bypass CloudFront path blocks (/grafana, /jaeger, …). Association cost when enabled.
# Prerequisites setup (generate PKI + Import both ACM certs + ALB SGs):
#   docs/client-vpn.md  →  section "Prerequisites setup"
# Both ARNs must be real imported ACM certs in us-east-1 (not Request public certs).
# ACM import always requires --private-key for both:
#   client_vpn_server_certificate_arn = server.crt + server.key (+ ca.crt chain)
#   client_vpn_client_ca_arn          = ca.crt + ca.key
# ──────────────────────────────────────────────
# Client VPN: internal ALB admin paths + EKS private API (cluster SG :443 from client CIDR).
# Public EKS endpoint remains enabled (dual access). See docs/client-vpn.md.
client_vpn_enabled                = true
client_vpn_client_cidr_block      = "10.100.0.0/22"
client_vpn_server_certificate_arn = "arn:aws:acm:us-east-1:493499579600:certificate/9b00812a-e340-42ce-9bbc-34f2361be15f"
client_vpn_client_ca_arn          = "arn:aws:acm:us-east-1:493499579600:certificate/9952f4c6-0e3d-4251-93a9-669b58432310"
# Recommended: all SGs on the storefront ALB (TCP 80 from client CIDR)
client_vpn_alb_security_group_ids = ["sg-085f3775c0408abb0", "sg-0bd7e89c21dffcd55"]
# Optional: omit for first private subnet only (cheapest). Explicit multi-AZ increases cost.
# client_vpn_subnet_ids = ["subnet-0ab17749536b34693"]

# ──────────────────────────────────────────────
# Private DNS — internal.hungtran.id.vn → ALB; services via path
# Requires cloudfront_origin_alb_arn (apex alias target). See docs/client-vpn.md
# ──────────────────────────────────────────────
private_dns_enabled   = true
private_dns_zone_name = "internal.hungtran.id.vn"
# HTTPS for https://internal.hungtran.id.vn — pass existing ISSUED ACM ARN (us-east-1).
# Issue cert outside Terraform (DNS validation in public DNS), same pattern as CloudFront.
# Also set chart values-prod publicAlb.certificateArn to the same ARN.
# private_dns_acm_certificate_arn = "arn:aws:acm:us-east-1:493499579600:certificate/<ID>"
private_dns_acm_certificate_arn = "arn:aws:acm:us-east-1:493499579600:certificate/043175b8-99f5-492f-a258-ff280e0b9a75"

access_entries = {
  "chinh_nguyen" = {
    principal_arn = "arn:aws:iam::493499579600:user/chinh-nguyen"
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  }
}

# ──────────────────────────────────────────────
# Cost budgets — onboarding ~$300/week × 3 weeks → monthly $900
# AWS Budgets: no WEEKLY time_unit (use MONTHLY + DAILY).
# SNS protocol: email-json. After apply: Confirm subscription in inbox.
# Account-level — only wire production (not development).
# ──────────────────────────────────────────────
cost_budgets_enabled = true
# Required when enabled — SNS email-json; Confirm subscription after apply.
cost_budgets_alert_email       = "ctran13904@gmail.com"
cost_budgets_monthly_limit_usd = "900"
cost_budgets_daily_limit_usd   = "45"
cost_budgets_create_daily      = true

# ──────────────────────────────────────────────
# Cost Anomaly Detection — spikes vs baseline (per SERVICE)
# Account-level; production only. Confirm email if AWS sends one.
# ──────────────────────────────────────────────
cost_anomaly_enabled             = true
cost_anomaly_alert_email         = "ctran13904@gmail.com"
cost_anomaly_frequency           = "DAILY"
cost_anomaly_impact_absolute_usd = "25"
cost_anomaly_impact_percentage   = "40"

# ──────────────────────────────────────────────
# Amazon MSK Configuration (Directive #8)
# ──────────────────────────────────────────────
msk_kafka_version        = "3.7.x"
msk_broker_instance_type = "kafka.t3.small"
msk_ebs_volume_size      = 10

# P2 Budget Actions — production manual approval only.
# Target role is wired from module.karpenter.controller_role_name in main.tf.
cost_budget_actions_enabled                     = true
cost_budget_action_monthly_threshold_percentage = 100
cost_budget_action_daily_threshold_percentage   = 100
cost_budget_daily_action_enabled                = false

# ──────────────────────────────────────────────
# P3 CUR + Athena + Grafana
# Existing BCM Data Export discovered in AWS:
#   export: finops-watch-cur
#   S3:    s3://company-cdo-493499579600-telemetry/cur/finops-watch-cur/data/
#   bucket region: ap-southeast-1
# ──────────────────────────────────────────────
cur_athena_enabled                      = true
cur_athena_region                       = "ap-southeast-1"
cur_athena_cur_bucket_name              = "company-cdo-493499579600-telemetry"
cur_athena_cur_s3_prefix                = "cur"
cur_athena_cur_export_name              = "finops-watch-cur"
cur_athena_database_name                = "finops_cur"
cur_athena_crawler_name                 = "techx-prod-tf2-cur-athena"
cur_athena_workgroup_name               = "grafana-cur"
cur_athena_results_bucket_name          = "techx-prod-tf2-athena-results-493499579600-ap-southeast-1"
cur_athena_bytes_cutoff                 = 1073741824
cur_athena_grafana_namespace            = "techx-corp-prod"
cur_athena_grafana_service_account_name = "grafana"

# Overlay: anomaly routing via AWS User Notifications email.
cost_anomaly_routing_enabled              = true
cost_anomaly_routing_email                = "ctran13904@gmail.com"
cost_anomaly_routing_regions              = ["us-east-1"]
cost_anomaly_routing_hub_region           = "us-east-1"
cost_anomaly_routing_impact_absolute_usd  = 25
cost_anomaly_routing_aggregation_duration = "SHORT"

# Overlay: Cost Optimization Hub recommendations export for sprint backlog.
cost_optimization_backlog_enabled                     = true
cost_optimization_backlog_bucket_name                 = "techx-prod-tf2-cost-optimization-exports-493499579600-us-east-1"
cost_optimization_backlog_s3_prefix                   = "cost-optimization"
cost_optimization_backlog_export_name                 = "cost-optimization-recommendations"
cost_optimization_backlog_create_export               = false
cost_optimization_backlog_database_name               = "finops_cost_optimization"
cost_optimization_backlog_crawler_name                = "techx-prod-tf2-cost-optimization-backlog"
cost_optimization_backlog_workgroup_name              = "cost-optimization-backlog"
cost_optimization_backlog_athena_bytes_cutoff         = 1073741824
cost_optimization_backlog_include_member_accounts     = false
cost_optimization_backlog_manage_enrollment           = false
cost_optimization_backlog_include_all_recommendations = false
# Change trail: @hungxqt - 2026-07-19 - Set ecr_image_tag_mutability to IMMUTABLE for all service repos.
