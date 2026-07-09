aws_region   = "us-east-1"
project_name = "techx-dev"

tags = {
  Environment = "development"
  Owner       = "CDO-03-06"
  Project     = "techx-platform"
}

# Image format: REGISTRY/techx-dev-corp/SERVICE:VERSION
# Module creates one nested ECR repo per platform service (default catalog).
ecr_project_name       = "techx-dev-corp"
ecr_naming_mode        = "nested"
ecr_keep_last_n_images = 10
ecr_scan_on_push       = true
ecr_force_delete       = true

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

# One managed node group per AZ so EBS volumes / pods can schedule in both zones.
# Replaces single multi-subnet NG (ASG could put all capacity in one AZ).
# Apply destroys techx-dev-general and creates techx-dev-general-1a + techx-dev-general-1b.
node_groups = {
  "general-1a" = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    # EKS 1.33+ rejects AL2_x86_64; use Amazon Linux 2023
    ami_type     = "AL2023_x86_64_STANDARD"
    disk_size    = 30
    desired_size = 1
    min_size     = 1
    max_size     = 2
    subnet_keys  = ["priv-1a"]
    labels = {
      role = "general"
      env  = "development"
      az   = "us-east-1a"
    }
  }
  "general-1b" = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_x86_64_STANDARD"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    subnet_keys    = ["priv-1b"]
    labels = {
      role = "general"
      env  = "development"
      az   = "us-east-1b"
    }
  }
}

addons = {
  "vpc-cni" = {
    addon_version = "v1.22.3-eksbuild.1"
  }
  "coredns" = {
    addon_version = "v1.14.3-eksbuild.3"
  }
  "kube-proxy" = {
    addon_version = "v1.36.0-eksbuild.9"
  }
  "aws-ebs-csi-driver" = {}
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
argocd_chart_repo_url = "https://github.com/tmcmanhcuong/techx-corp-chart.git"

# ──────────────────────────────────────────────
# Storefront public ALB path blocking (Helm)
# ──────────────────────────────────────────────
storefront_alb_block_sensitive_paths = false

secrets_manager_recovery_window_in_days = 0
