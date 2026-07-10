aws_region   = "us-east-1"
project_name = "techx"

tags = {
  Environment = "production"
  Owner       = "CDO-03-06"
  Project     = "techx-platform"
}

# Image format: REGISTRY/techx-corp/SERVICE:VERSION
# Module creates one nested ECR repo per platform service (default catalog).
ecr_project_name       = "techx-corp"
ecr_naming_mode        = "nested"
ecr_keep_last_n_images = 20
ecr_scan_on_push       = true
ecr_force_delete       = true

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
cluster_name       = "techx-tf2"
kubernetes_version = "1.32"

# One managed node group per AZ (EBS / StatefulSet scheduling across zones).
# Apply destroys techx-tf2-general and creates techx-tf2-general-1a + techx-tf2-general-1b.
node_groups = {
  "general-1a" = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    # Prefer AL2023 (AL2 only supported through k8s 1.32)
    ami_type     = "AL2023_x86_64"
    disk_size    = 30
    desired_size = 1
    min_size     = 1
    max_size     = 2
    subnet_keys  = ["priv-1a"]
    labels = {
      role = "general"
      az   = "us-east-1a"
    }
  }
  "general-1b" = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    ami_type       = "AL2023_x86_64"
    disk_size      = 30
    desired_size   = 1
    min_size       = 1
    max_size       = 2
    subnet_keys    = ["priv-1b"]
    labels = {
      role = "general"
      az   = "us-east-1b"
    }
  }
}

addons = {
  "vpc-cni"            = {}
  "coredns"            = {}
  "kube-proxy"         = {}
  "aws-ebs-csi-driver" = {}
}

# ──────────────────────────────────────────────
# GitHub Actions → ECR push (OIDC)
# ──────────────────────────────────────────────
github_repository            = "tmcmanhcuong/tf2-corp-platform"
github_actions_ecr_role_name = "techx-gha-platform-prod"
github_actions_environments  = ["production"]
github_actions_allowed_refs  = ["refs/heads/main", "refs/tags/v*"]
create_github_oidc_provider  = true

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
