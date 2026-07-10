# ──────────────────────────────────────────────
# IAM Role cho EKS Control Plane
# ──────────────────────────────────────────────

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ──────────────────────────────────────────────
# IAM Role dùng chung cho tất cả Node Groups
# ──────────────────────────────────────────────

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_ebs_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.node.name
}

# ──────────────────────────────────────────────
# EKS Cluster (Control Plane)
# ──────────────────────────────────────────────

resource "aws_eks_cluster" "this" {
  name                          = var.cluster_name
  version                       = var.kubernetes_version
  role_arn                      = aws_iam_role.cluster.arn
  bootstrap_self_managed_addons = false

  # STANDARD = regular support window (no extended-support billing after end of standard support).
  # EXTENDED keeps the cluster on an older version past standard EOL (extra cost).
  upgrade_policy {
    support_type = var.upgrade_policy_support_type
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = var.endpoint_public_access
    endpoint_private_access = var.endpoint_private_access
    public_access_cidrs     = var.public_access_cidrs
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]
}

# Karpenter security-group discovery (EC2NodeClass securityGroupSelectorTerms).
# Cluster SG is created by EKS; tag it so nodes join the same cluster SG fabric.
resource "aws_ec2_tag" "cluster_sg_karpenter_discovery" {
  count = var.enable_karpenter_discovery_tags ? 1 : 0

  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# ──────────────────────────────────────────────
# Managed Node Groups
# ──────────────────────────────────────────────

# ──────────────────────────────────────────────
# EKS Managed Add-ons
#
# bootstrap_self_managed_addons = false means EKS does NOT install
# vpc-cni / kube-proxy / coredns automatically. Network addons MUST be
# created before (or at least without waiting on) node groups; otherwise
# nodes stay NotReady with "cni plugin not initialized" and node-group
# create can hang while addons wait on node groups (deadlock).
# ──────────────────────────────────────────────

locals {
  # CNI + kube-proxy are required for nodes to become NetworkReady.
  network_addon_names = toset(["vpc-cni", "kube-proxy"])

  # Auto-wire EBS CSI IRSA when addon is requested without an explicit role ARN.
  # Prevents controller CrashLoopBackOff when IMDS is unreachable from pods.
  addons_effective = {
    for name, cfg in var.addons : name => {
      addon_version = cfg.addon_version
      service_account_role_arn = (
        name == "aws-ebs-csi-driver" && cfg.service_account_role_arn == null
        ? aws_iam_role.ebs_csi_controller.arn
        : cfg.service_account_role_arn
      )
    }
  }

  network_addons = {
    for name, cfg in local.addons_effective : name => cfg
    if contains(local.network_addon_names, name)
  }

  # CoreDNS, EBS CSI, etc. need worker nodes present.
  post_node_addons = {
    for name, cfg in local.addons_effective : name => cfg
    if !contains(local.network_addon_names, name)
  }
}

resource "aws_eks_addon" "network" {
  for_each = local.network_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value.addon_version
  service_account_role_arn    = each.value.service_account_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_cluster.this]
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-${each.key}"
  node_role_arn   = aws_iam_role.node.arn

  # Nếu node group không chỉ định subnet riêng thì dùng subnet của cluster
  subnet_ids = each.value.subnet_ids != null ? each.value.subnet_ids : var.subnet_ids

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type
  disk_size      = each.value.disk_size
  labels         = each.value.labels

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
    aws_iam_role_policy_attachment.node_ebs_policy,
    # Ensure CNI is present before nodes are expected to become Ready.
    aws_eks_addon.network,
  ]
}

resource "aws_eks_addon" "this" {
  for_each = local.post_node_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value.addon_version
  service_account_role_arn    = each.value.service_account_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi_controller,
  ]
}
