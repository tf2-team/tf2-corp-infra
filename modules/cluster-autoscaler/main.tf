# ──────────────────────────────────────────────
# Cluster Autoscaler — optional IRSA + Helm
#
# Scales EKS managed node group ASGs (min/max from Terraform).
# Default platform path is MNG floor + Karpenter; keep this module
# disabled unless deliberately running CA-only mode.
# ──────────────────────────────────────────────

data "aws_caller_identity" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = var.enabled ? 1 : 0
}

locals {
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")
  sa_subject       = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
  partition        = var.enabled ? data.aws_partition.current[0].partition : "aws"
  account_id       = var.enabled ? data.aws_caller_identity.current[0].account_id : "000000000000"
  # ASG ARN shape for SetDesiredCapacity / TerminateInstanceInAutoScalingGroup (CKV_AWS_356).
  asg_resource_arns = [
    "arn:${local.partition}:autoscaling:${var.aws_region}:${local.account_id}:autoScalingGroup:*:autoScalingGroupName/*",
  ]
}

# ── IAM policy (AWS CA recommendations + tag-scoped mutate) ─
# Describe* / GetInstanceTypes* are not resource-level in IAM → resources=["*"] is required.
# Mutate is scoped to ASG ARNs + ResourceTag condition (cluster ownership).

data "aws_iam_policy_document" "cluster_autoscaler" {
  # checkov:skip=CKV_AWS_356: Describe/GetInstanceTypes APIs have no resource-level ARNs; mutate is ASG ARN + tag condition
  count = var.enabled ? 1 : 0

  statement {
    sid    = "ClusterAutoscalerDescribe"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "ec2:DescribeInstances",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  # Mutating ASG actions: ARN pattern + tag condition for this cluster's CA-owned ASGs.
  statement {
    sid    = "ClusterAutoscalerMutateTaggedASGs"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = local.asg_resource_arns
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  count = var.enabled ? 1 : 0

  name        = "${var.cluster_name}-cluster-autoscaler"
  path        = "/"
  description = "Cluster Autoscaler permissions for EKS managed node group ASGs"
  policy      = data.aws_iam_policy_document.cluster_autoscaler[0].json
  tags        = var.tags
}

# ── IRSA trust ────────────────────────────────

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  count = var.enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:sub"
      values   = [local.sa_subject]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [var.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  count = var.enabled ? 1 : 0

  name               = "${var.cluster_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.cluster_autoscaler[0].name
  policy_arn = aws_iam_policy.cluster_autoscaler[0].arn
}

# ── Optional: install Cluster Autoscaler Helm chart ─

resource "helm_release" "cluster_autoscaler" {
  count = var.enabled && var.install_helm ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.chart_version
  namespace  = var.namespace

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  values = [
    yamlencode({
      fullnameOverride = "cluster-autoscaler"
      cloudProvider    = "aws"
      awsRegion        = var.aws_region
      autoDiscovery = {
        clusterName = var.cluster_name
        tags = [
          "k8s.io/cluster-autoscaler/enabled",
          "k8s.io/cluster-autoscaler/${var.cluster_name}",
        ]
      }
      rbac = {
        create = true
        serviceAccount = {
          create = true
          name   = var.service_account_name
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler[0].arn
          }
        }
      }
      extraArgs = {
        balance-similar-node-groups = var.balance_similar_node_groups
        skip-nodes-with-system-pods = var.skip_nodes_with_system_pods
        scale-down-delay-after-add  = var.scale_down_delay_after_add
        scale-down-unneeded-time    = var.scale_down_unneeded_time
        expander                    = "least-waste"
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_autoscaler,
  ]
}
