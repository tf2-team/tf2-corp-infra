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

# Mandate 18: Flow Logs are deliberately opt-in. NAT Gateway CloudWatch metrics
# provide always-on live evidence; Flow Logs are enabled only for a bounded
# Cross-AZ investigation because CloudWatch Logs ingestion has its own cost.
data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.flow_logs_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.flow_logs_enabled ? 1 : 0

  name               = "${var.name}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = {
    Name    = "${var.name}-flow-logs"
    Purpose = "on-demand-network-cost-investigation"
  }
}

data "aws_iam_policy_document" "flow_logs_delivery" {
  count = var.flow_logs_enabled ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs_delivery" {
  count = var.flow_logs_enabled ? 1 : 0

  name   = "${var.name}-flow-logs-delivery"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_delivery[0].json
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_158:Short-lived diagnostic Flow Logs use the AWS-managed key to avoid creating a dedicated KMS key solely for an opt-in measurement window.
  count = var.flow_logs_enabled ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_in_days

  tags = {
    Name    = "${var.name}-flow-logs"
    Purpose = "on-demand-network-cost-investigation"
  }
}

resource "aws_flow_log" "vpc" {
  count = var.flow_logs_enabled ? 1 : 0

  iam_role_arn         = aws_iam_role.flow_logs[0].arn
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.this.id

  # One-minute records are required to compare two bounded 15-minute load-test
  # windows. Flow Logs are already opt-in through flow_logs_enabled.
  max_aggregation_interval = 60

  # Keep the fields needed to identify a traffic pair, direction and volume.
  # The destination AZ is resolved from the related ENI/subnet during review;
  # Flow Logs do not expose a billed Cross-AZ byte counter by themselves.
  log_format = "$${version} $${account-id} $${interface-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${packets} $${bytes} $${start} $${end} $${action} $${log-status} $${az-id} $${flow-direction}"

  tags = {
    Name    = "${var.name}-flow-logs"
    Purpose = "on-demand-network-cost-investigation"
  }

  depends_on = [aws_iam_role_policy.flow_logs_delivery]
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
