aws_region   = "us-east-1"
project_name = "techx-dev-tf2"

tags = {
  Environment = "development"
  Owner       = "CDO-03-06"
  Project     = "techx-platform"
}

# Image format: REGISTRY/techx-dev-corp/SERVICE:VERSION
# Module creates one nested ECR repo per platform service (default catalog).
ecr_project_name           = "techx-dev-corp"
ecr_naming_mode            = "nested"
ecr_keep_last_n_images     = 5
ecr_keep_last_n_buildcache = 1
ecr_scan_on_push           = true
ecr_force_delete           = true

# ──────────────────────────────────────────────
# VPC Configuration
# Non-overlapping CIDR with production (10.0.0.0/16)
# ──────────────────────────────────────────────
vpc_cidr_block = "10.1.0.0/16"

public_subnets = {
  "pub-1a" = {
    cidr_block        = "10.1.1.0/24"
    availability_zone = "us-east-1a"
  }
  "pub-1b" = {
    cidr_block        = "10.1.2.0/24"
    availability_zone = "us-east-1b"
  }
}

private_subnets = {
  "priv-1a" = {
    cidr_block        = "10.1.10.0/24"
    availability_zone = "us-east-1a"
    nat_gateway_key   = "nat-1a"
  }
  "priv-1b" = {
    cidr_block        = "10.1.11.0/24"
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
# EKS Configuration (cost-optimized for development)
# ──────────────────────────────────────────────
cluster_name       = "techx-dev"
kubernetes_version = "1.36"

# Critical floor (hard placement): system-* MNG (On-Demand, workload-class=critical).
# general-* are legacy dual-run capacity during migration — leave unchanged in create-system
# plans to avoid accidental replace/destroy. Drain and remove general-* only after acceptance.
# Phase 1 has no Cluster Autoscaler; max_size is an emergency ceiling only (no auto scale-out).
# One managed node group per AZ so EBS volumes / pods can schedule in both zones.
node_groups = {
  # Legacy migration capacity (do not change instance/lifecycle here while creating system-*).

  # New critical floor (create-only in first migration plan).
  "system-1a" = {
    instance_types = ["t3.medium"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_x86_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    max_pods       = 110
    subnet_keys    = ["priv-1a"]
    labels = {
      role           = "critical"
      workload-class = "critical"
      env            = "development"
      az             = "us-east-1a"
    }
  }
  "system-1b" = {
    instance_types = ["t3.medium"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_x86_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    max_pods       = 110
    subnet_keys    = ["priv-1b"]
    labels = {
      role           = "critical"
      workload-class = "critical"
      env            = "development"
      az             = "us-east-1b"
    }
  }
}

addons = {
  "vpc-cni" = {
    addon_version = "v1.22.3-eksbuild.1"
    # ENABLE_PREFIX_DELEGATION raises IP density; pair with node max_pods / Karpenter node_max_pods
    # Raw JSON string (jsonencode is not allowed in .tfvars)
    configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\",\"WARM_PREFIX_TARGET\":\"1\"}}"
  }
  "coredns" = {
    addon_version = "v1.14.3-eksbuild.3"
    # Pin CoreDNS to critical MNG (schema supports nodeSelector for this addon version).
    configuration_values = "{\"nodeSelector\":{\"workload-class\":\"critical\"}}"
  }
  "kube-proxy" = {
    addon_version = "v1.36.0-eksbuild.9"
  }
  "aws-ebs-csi-driver" = {
    # Pin controller only; ebs-csi-node DaemonSet stays universal (no workload-class selector).
    configuration_values = "{\"controller\":{\"nodeSelector\":{\"workload-class\":\"critical\"}}}"
  }
}

# ──────────────────────────────────────────────
# GitHub Actions → ECR push (OIDC)
# OIDC provider is created by production; this env reuses it.
# ──────────────────────────────────────────────
github_repository            = "tmcmanhcuong/tf2-corp-platform"
github_actions_ecr_role_name = "techx-gha-platform-dev"
github_actions_environments  = ["development"]
github_actions_allowed_refs  = ["refs/heads/techx-dev-corp"]
create_github_oidc_provider  = false

# ──────────────────────────────────────────────
# Argo CD (REL-09) — set true when ready to install control plane
# Requires: aws eks update-kubeconfig + cluster API reachable during apply
# ──────────────────────────────────────────────
argocd_enabled       = true
argocd_chart_version = "7.8.28"
# Override if chart lives under a different GitHub path:
argocd_chart_repo_url = "https://github.com/tmcmanhcuong/tf2-corp-chart/tree/techx-dev-corp"

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm)
# ──────────────────────────────────────────────
storefront_alb_block_sensitive_paths = false

secrets_manager_recovery_window_in_days = 0

# ──────────────────────────────────────────────
# Karpenter (node autoscaling) — Spot preferred
# Requires: cluster API reachable when install_helm / create_node_resources are true
# Default capacity model: critical MNG floor + Karpenter elastic (do not enable CA Helm with this).
# CRD and controller must share chart_version; upgrade CRD before controller.
# ──────────────────────────────────────────────
karpenter_enabled               = true
karpenter_install_helm          = true
karpenter_create_node_resources = true
karpenter_chart_version         = "1.13.1"
karpenter_spot_preferred        = true
karpenter_nodepool_cpu_limit    = "32"
karpenter_nodepool_memory_limit = "64Gi"
karpenter_availability_zones    = ["us-east-1a", "us-east-1b"]
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
# Migration freeze: open per pool after acceptance (spot first, then on-demand, then both "1")
karpenter_disruption_budget_nodes = {
  spot      = "0"
  on_demand = "0"
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
