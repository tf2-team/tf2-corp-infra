# ──────────────────────────────────────────────
# Locals
# ──────────────────────────────────────────────

locals {
  # Chỉ private subnets có nat_gateway_key mới được gắn vào private route table
  private_subnets_with_nat = {
    for k, v in var.private_subnets : k => v
    if v.nat_gateway_key != null
  }

  # EKS tags cho public subnets (chỉ gắn khi eks_cluster_name được truyền vào)
  eks_public_tags = var.eks_cluster_name != null ? {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
    "kubernetes.io/role/elb"                        = "1"
  } : {}

  # Base EKS cluster shared tag for private subnets (internal-elb is per-subnet optional).
  eks_private_cluster_tags = var.eks_cluster_name != null ? {
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  } : {}

  # Karpenter discovery value (applied per subnet when enable_karpenter_discovery is true).
  karpenter_discovery_value = (
    var.eks_cluster_name != null && var.enable_karpenter_discovery_tags
    ? var.eks_cluster_name
    : null
  )
}

# ──────────────────────────────────────────────
# VPC
# ──────────────────────────────────────────────

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  tags = {
    Name = var.name
  }
}

# ──────────────────────────────────────────────
# Internet Gateway
# ──────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

# ──────────────────────────────────────────────
# Public Subnets — for_each phẳng
# ──────────────────────────────────────────────

resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = true

  tags = merge(local.eks_public_tags, {
    Name = "${var.name}-public-${each.key}"
    Tier = "public"
  })
}

# ──────────────────────────────────────────────
# Private Subnets — for_each phẳng
# ──────────────────────────────────────────────

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone

  tags = merge(
    local.eks_private_cluster_tags,
    (
      var.eks_cluster_name != null && each.value.enable_eks_internal_elb
      ? { "kubernetes.io/role/internal-elb" = "1" }
      : {}
    ),
    (
      local.karpenter_discovery_value != null && each.value.enable_karpenter_discovery
      ? { "karpenter.sh/discovery" = local.karpenter_discovery_value }
      : {}
    ),
    {
      Name = "${var.name}-private-${each.key}"
      Tier = "private"
    }
  )
}

# ──────────────────────────────────────────────
# Elastic IPs + NAT Gateways — for_each phẳng, cùng key với var.nat_gateways
# ──────────────────────────────────────────────

resource "aws_eip" "nat" {
  for_each = var.nat_gateways

  domain = "vpc"

  tags = {
    Name = "${var.name}-eip-${each.key}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = var.nat_gateways

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.value.public_subnet_key].id

  tags = {
    Name = "${var.name}-${each.key}"
  }

  depends_on = [aws_internet_gateway.this]
}

# ──────────────────────────────────────────────
# Route Table: Public — 1 bảng dùng chung cho tất cả public subnets
# ──────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  for_each = var.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# ──────────────────────────────────────────────
# Route Tables: Private — 1 bảng per NAT Gateway
# Các private subnet trỏ vào bảng này qua nat_gateway_key
# ──────────────────────────────────────────────

resource "aws_route_table" "private" {
  for_each = var.nat_gateways

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[each.key].id
  }

  tags = {
    Name = "${var.name}-rt-private-${each.key}"
  }
}

# Chỉ gắn association cho subnet có nat_gateway_key (không lặp lồng nhau)
resource "aws_route_table_association" "private" {
  for_each = local.private_subnets_with_nat

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.value.nat_gateway_key].id
}
# Change trail: @hungxqt - 2026-07-14 - Large /20 node subnets for VPC CNI prefix IP headroom.
