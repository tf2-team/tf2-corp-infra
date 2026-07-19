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

  # Pin cluster access mode so apply does not leave API-only / ConfigMap-only drift
  # that then has to be fixed in the console. Cluster creator gets admin via bootstrap.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

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
      configuration_values = cfg.configuration_values
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

  # Launch templates only when max_pods is set (AL2023 NodeConfig kubelet.maxPods).
  node_groups_with_max_pods = {
    for name, ng in var.node_groups : name => ng
    if ng.max_pods != null
  }

  # Cluster Autoscaler discovery tags only on matching MNG keys (default: system-*).
  # Karpenter nodes are not in ASGs; non-system MNGs stay untagged so CA never owns them.
  cluster_autoscaler_node_groups = var.enable_cluster_autoscaler_asg_tags ? {
    for name, ng in aws_eks_node_group.this : name => ng
    if anytrue([
      for prefix in var.cluster_autoscaler_node_group_name_prefixes :
      startswith(name, prefix)
    ])
  } : {}
}

resource "aws_eks_addon" "network" {
  for_each = local.network_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value.addon_version
  service_account_role_arn    = each.value.service_account_role_arn
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_cluster.this]
}

# AL2023 NodeConfig via launch template: raise kubelet maxPods for prefix-delegation density.
# disk_size must live on the LT (not the node group) when launch_template is set.
resource "aws_launch_template" "node" {
  for_each = local.node_groups_with_max_pods

  name_prefix = "${var.cluster_name}-${each.key}-"
  description = "EKS MNG ${var.cluster_name}-${each.key}: maxPods=${each.value.max_pods}"

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = each.value.disk_size
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # Require IMDSv2 (CKV_AWS_79). hop_limit=1 blocks pod SSRF to IMDS; IRSA does not need IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  # MIME multipart NodeConfig; EKS merges cluster bootstrap for managed node groups.
  user_data = base64encode(<<-EOT
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="BOUNDARY"

--BOUNDARY
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  kubelet:
    config:
      maxPods: ${each.value.max_pods}

--BOUNDARY--
EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-${each.key}"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
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
  # disk_size is set on the launch template when max_pods is configured.
  disk_size = each.value.max_pods != null ? null : each.value.disk_size
  labels    = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  dynamic "launch_template" {
    for_each = each.value.max_pods != null ? [1] : []
    content {
      id      = aws_launch_template.node[each.key].id
      version = aws_launch_template.node[each.key].latest_version
    }
  }

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  # desired_size is bootstrap / floor only. Cluster Autoscaler (system MNG) and
  # operators may change ASG desired between applies; Terraform must not thrash it.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
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

# Cluster Autoscaler auto-discovery tags on system-* managed node group ASGs only.
# Karpenter-provisioned EC2 is never in these ASGs; non-matching MNGs stay untagged.
resource "aws_autoscaling_group_tag" "cluster_autoscaler_enabled" {
  for_each = local.cluster_autoscaler_node_groups

  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "cluster_autoscaler_cluster" {
  for_each = local.cluster_autoscaler_node_groups

  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

resource "aws_eks_addon" "this" {
  for_each = local.post_node_addons

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = each.value.addon_version
  service_account_role_arn    = each.value.service_account_role_arn
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachment.ebs_csi_controller,
  ]
}

# EKS Access Entry API rejects kubernetes_groups that start with "system:"
# (e.g. system:masters from the old aws-auth ConfigMap model).
# Use a STANDARD entry + AmazonEKSClusterAdminPolicy instead.
resource "aws_eks_access_entry" "plan_role" {
  count = var.plan_role_arn != null ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.plan_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "plan_role" {
  count = var.plan_role_arn != null ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.plan_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.plan_role]
}

# ──────────────────────────────────────────────
# EKS Access Entries (Additional map-based configuration)
# ──────────────────────────────────────────────

resource "aws_eks_access_entry" "additional" {
  for_each          = var.access_entries
  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = each.value.kubernetes_groups
}

resource "aws_eks_access_policy_association" "additional" {
  for_each = {
    for k, v in var.access_entries : k => v
    if v.policy_arn != null
  }

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.additional]
}

# Change trail: @hungxqt - 2026-07-19 - Tag only system-* MNG ASGs for CA; ignore desired_size drift.

