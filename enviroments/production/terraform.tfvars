aws_region   = "us-east-1"
project_name = "techx-production-tf2"

tags = {
  Environment = "production"
  Owner       = "CDO-03"
}

repositories = {
  "corp" = {
    image_tag_mutability = "MUTABLE"
    scan_on_push         = true
    keep_last_n_images   = 20
    force_delete         = true
  }
}

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
kubernetes_version = "1.31"

node_groups = {
  "general" = {
    instance_types = ["t3.large"]
    capacity_type  = "ON_DEMAND"
    disk_size      = 30
    desired_size   = 2
    min_size       = 2
    max_size       = 4
    labels = {
      role = "general"
    }
  }
}

addons = {
  "vpc-cni"    = {}
  "coredns"    = {}
  "kube-proxy" = {}
}
