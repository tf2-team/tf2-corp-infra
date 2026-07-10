aws_region   = "us-east-1"
project_name = "techx-dev-tf2"

tags = {
  Environment = "dev"
  Owner       = "CDO-03"
}

repositories = {
  "corp" = {
    image_tag_mutability = "MUTABLE"
    scan_on_push         = true
    keep_last_n_images   = 10
    force_delete         = true
  }
}

vpc_cidr_block = "10.10.0.0/16"

public_subnets = {
  "pub-1a" = {
    cidr_block        = "10.10.1.0/24"
    availability_zone = "us-east-1a"
  }
  "pub-1b" = {
    cidr_block        = "10.10.2.0/24"
    availability_zone = "us-east-1b"
  }
}

private_subnets = {
  "priv-1a" = {
    cidr_block        = "10.10.10.0/24"
    availability_zone = "us-east-1a"
    nat_gateway_key   = "nat-1a"
  }
  "priv-1b" = {
    cidr_block        = "10.10.11.0/24"
    availability_zone = "us-east-1b"
    nat_gateway_key   = "nat-1a"
  }
}

nat_gateways = {
  "nat-1a" = {
    public_subnet_key = "pub-1a"
  }
}

cluster_name       = "techx-dev"
kubernetes_version = "1.36"

node_groups = {
  "general" = {
    instance_types = ["t3.medium"]
    capacity_type  = "ON_DEMAND"
    disk_size      = 20
    desired_size   = 1
    min_size       = 1
    max_size       = 2
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
