aws_region   = "us-east-1"
project_name = "techx-prod-tf2"

tags = {
  Environment = "production"
  Owner       = "CDO-03-06"
  Project     = "techx-platform"
}

# Image format: REGISTRY/techx-corp/SERVICE:VERSION
# Module creates one nested ECR repo per platform service (default catalog).
ecr_project_name           = "techx-prod-corp"
ecr_naming_mode            = "nested"
ecr_keep_last_n_images     = 20
ecr_keep_last_n_buildcache = 1
ecr_scan_on_push           = true
ecr_force_delete           = true

# ──────────────────────────────────────────────
# VPC Configuration
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
# EKS Configuration
# ──────────────────────────────────────────────
cluster_name       = "techx-tf2-prod"
kubernetes_version = "1.36"

# Critical floor (hard placement): system-* MNG (On-Demand, workload-class=critical).
# general-* remain as legacy dual-run capacity until production placement acceptance.
# Phase 1 has no Cluster Autoscaler; max_size is an emergency ceiling only (no auto scale-out).
# One managed node group per AZ (EBS / StatefulSet scheduling across zones).
node_groups = {
  # Legacy migration capacity — leave capacity/lifecycle unchanged in create-system plans.
  "general-1a" = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    # Prefer AL2023 (AL2 only supported through k8s 1.32)
    ami_type     = "AL2023_x86_64_STANDARD"
    disk_size    = 30
    desired_size = 1
    min_size     = 1
    max_size     = 2
    # Prefix-delegation density (default ENI mode maxPods=35 fills with system+app+DS)
    max_pods    = 110
    subnet_keys = ["priv-1a"]
    labels = {
      role           = "critical"
      workload-class = "critical"
      az             = "us-east-1a"
    }
    # Phase 2 hard isolation (disabled): only enable after DaemonSets/system pods tolerate.
    # taints = [{ key = "workload-class", value = "critical", effect = "NO_SCHEDULE" }]
  }
  "general-1b" = {
    instance_types = ["t3.large"]
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
      az             = "us-east-1b"
    }
  }
  # New critical floor (create-only in first production placement plan).
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
      az             = "us-east-1b"
    }
  }
}

addons = {
  "vpc-cni" = {
    # Raw JSON string (jsonencode is not allowed in .tfvars)
    configuration_values = "{\"env\":{\"ENABLE_PREFIX_DELEGATION\":\"true\",\"WARM_PREFIX_TARGET\":\"1\"}}"
  }
  "coredns" = {
    configuration_values = "{\"nodeSelector\":{\"workload-class\":\"critical\"}}"
  }
  "kube-proxy" = {}
  "aws-ebs-csi-driver" = {
    configuration_values = "{\"controller\":{\"nodeSelector\":{\"workload-class\":\"critical\"}}}"
  }
}

# ──────────────────────────────────────────────
# GitHub Actions → ECR push (OIDC)
# ──────────────────────────────────────────────
github_repository            = "tmcmanhcuong/tf2-corp-platform"
github_actions_ecr_role_name = "techx-gha-platform-prod"
github_actions_environments  = ["production"]
github_actions_allowed_refs  = ["refs/heads/main", "refs/tags/v*"]
create_github_oidc_provider  = false

# ──────────────────────────────────────────────
# Argo CD (REL-09) — keep false until dev cutover is proven
# ──────────────────────────────────────────────
argocd_enabled       = false
argocd_chart_version = "7.8.28"

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm)
# true  = block /grafana,/jaeger,/loadgen,/feature,/flagservice,/otlp-http (403)
# false = allow all paths through to frontend-proxy
# ──────────────────────────────────────────────
storefront_alb_block_sensitive_paths = true

# ──────────────────────────────────────────────
# Karpenter (node autoscaling) — On-Demand only for initial production placement
# IAM/SQS enabled; set install_helm + create_node_resources true when cluster API is ready
# Spot enablement is a separate post-acceptance rollout (do not enable with first placement).
# CRD and controller must share chart_version; upgrade CRD before controller.
# ──────────────────────────────────────────────
karpenter_enabled               = true
karpenter_install_helm          = false
karpenter_create_node_resources = false
karpenter_chart_version         = "1.13.1"
karpenter_spot_preferred        = false
karpenter_nodepool_cpu_limit    = "64"
karpenter_nodepool_memory_limit = "128Gi"
karpenter_availability_zones    = ["us-east-1a", "us-east-1b"]
# Applied when karpenter_create_node_resources=true; matches MNG density
karpenter_node_max_pods    = 110
karpenter_min_instance_cpu = 2
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
# Migration freeze until production placement acceptance
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
