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
ecr_keep_last_n_images     = 5
ecr_keep_last_n_buildcache = 1
ecr_scan_on_push           = false
ecr_force_delete           = true

# ──────────────────────────────────────────────
# VPC Configuration
# Non-overlapping CIDR with development (10.1.0.0/16)
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
  "priv-1a" = {
    cidr_block        = "10.0.10.0/24"
    availability_zone = "us-east-1a"
    nat_gateway_key   = "nat-1a"
  }
  "priv-1b" = {
    cidr_block        = "10.0.11.0/24"
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

node_groups = {
  "system-1a" = {
    instance_types = ["t4g.medium"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_ARM_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    max_pods       = 110
    subnet_keys    = ["priv-1a"]
    labels = {
      role           = "critical"
      workload-class = "critical"
      env            = "production"
      az             = "us-east-1a"
    }
  }
  "system-1b" = {
    instance_types = ["t4g.medium"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_ARM_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    max_pods       = 110
    subnet_keys    = ["priv-1b"]
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
# Argo CD (REL-09) — same enablement model as development
# Requires: aws eks update-kubeconfig + cluster API reachable during apply
# ──────────────────────────────────────────────
argocd_enabled       = true
argocd_chart_version = "7.8.28"
# Override if chart lives under a different GitHub path:
argocd_chart_repo_url = "https://github.com/tf2-team/tf2-corp-chart/tree/main"

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm)
# Aligned with development: allow all paths through to frontend-proxy
# ──────────────────────────────────────────────
storefront_alb_block_sensitive_paths = false

# Force-delete secret shells (same as development) for faster tear-down / re-bootstrap
secrets_manager_recovery_window_in_days = 0

# Force-delete secret shells (same as development) for faster tear-down / re-bootstrap
secrets_manager_recovery_window_in_days = 0

# ──────────────────────────────────────────────
# Karpenter (node autoscaling) — Spot preferred (same as development)
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
# Steady state: one voluntary disruption per NodePool so consolidation can reclaim idle capacity.
# Freeze to "0"/"0" only during multi-minor Karpenter upgrades or placement migrations.
karpenter_disruption_budget_nodes = {
  spot      = "1"
  on_demand = "1"
}
# Short reclaim window (WhenEmptyOrUnderutilized) — same as development.
karpenter_consolidate_after = "1m"

# ──────────────────────────────────────────────
# Cluster Autoscaler — OFF by default
# Scales managed node group ASGs only (within min_size/max_size).
# For CA-only experiments: disable Karpenter install/NodePools first, then enable CA.
# See docs/cluster-autoscaler.md
# ──────────────────────────────────────────────
cluster_autoscaler_enabled       = false
cluster_autoscaler_install_helm  = false
cluster_autoscaler_chart_version = "9.46.6"
