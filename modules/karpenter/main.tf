# ──────────────────────────────────────────────
# Karpenter — controller IRSA, node role, SQS interruption,
# optional Helm install, optional EC2NodeClass + NodePool CRs.
#
# System managed node groups remain the bootstrap path; Karpenter
# scales workload capacity from Pending pods.
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

  node_role_name = coalesce(var.node_iam_role_name, "${var.cluster_name}-karpenter-node")
  controller_role_name = coalesce(
    var.controller_iam_role_name,
    "${var.cluster_name}-karpenter-controller"
  )

  # Queue name matches official Getting Started (cluster name).
  interruption_queue_name = var.cluster_name

  partition  = var.enabled ? data.aws_partition.current[0].partition : "aws"
  account_id = var.enabled ? data.aws_caller_identity.current[0].account_id : "000000000000"
  region     = var.aws_region

  discovery = var.discovery_tag_value

  # Optional min vCPU: Gt (min-1) so min_instance_cpu=2 → instance-cpu > 1.
  min_cpu_requirement = var.min_instance_cpu > 0 ? [{
    key      = "karpenter.k8s.aws/instance-cpu"
    operator = "Gt"
    values   = [tostring(var.min_instance_cpu - 1)]
  }] : []

  node_requirements_base = concat(
    [
      {
        key      = "kubernetes.io/arch"
        operator = "In"
        values   = ["arm64"]
      },
      {
        key      = "kubernetes.io/os"
        operator = "In"
        values   = ["linux"]
      },
      {
        key      = "karpenter.k8s.aws/instance-category"
        operator = "In"
        values   = var.instance_categories
      },
      {
        key      = "karpenter.k8s.aws/instance-generation"
        operator = "Gt"
        values   = ["2"]
      },
      {
        key      = "topology.kubernetes.io/zone"
        operator = "In"
        values   = var.availability_zones
      },
    ],
    local.min_cpu_requirement,
  )

  spot_requirements = concat(local.node_requirements_base, [{
    key      = "karpenter.sh/capacity-type"
    operator = "In"
    values   = ["spot"]
  }])

  on_demand_requirements = concat(local.node_requirements_base, [{
    key      = "karpenter.sh/capacity-type"
    operator = "In"
    values   = ["on-demand"]
  }])
}

# When both NodePools are enabled, Spot weight must be strictly preferred.
check "nodepool_weight_preference" {
  assert {
    condition = (
      !var.spot_preferred ||
      var.nodepool_weights.spot > var.nodepool_weights.on_demand
    )
    error_message = "When spot_preferred is true, nodepool_weights.spot must be greater than nodepool_weights.on_demand."
  }
}

# ── Node IAM role (passed to EC2 by Karpenter) ─

data "aws_iam_policy_document" "node_assume" {
  count = var.enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  count = var.enabled ? 1 : 0

  name               = local.node_role_name
  assume_role_policy = data.aws_iam_policy_document.node_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.node[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.node[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr" {
  count = var.enabled ? 1 : 0

  role = aws_iam_role.node[0].name
  # Align with managed node group policies in modules/eks.
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.node[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Authorize Karpenter nodes to join the cluster (EKS access entries API).
resource "aws_eks_access_entry" "node" {
  count = var.enabled ? 1 : 0

  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node[0].arn
  type          = "EC2_LINUX"
}

# ── Interruption queue (Spot + health + state-change) ─

resource "aws_sqs_queue" "interruption" {
  count = var.enabled ? 1 : 0

  name                      = local.interruption_queue_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

data "aws_iam_policy_document" "interruption_queue" {
  count = var.enabled ? 1 : 0

  statement {
    sid    = "AllowEventBridgeAndSQS"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption[0].arn]
  }

  statement {
    sid    = "DenyHTTP"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.interruption[0].arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  count = var.enabled ? 1 : 0

  queue_url = aws_sqs_queue.interruption[0].url
  policy    = data.aws_iam_policy_document.interruption_queue[0].json
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  count = var.enabled ? 1 : 0

  name = "${var.cluster_name}-karpenter-spot-interruption"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  count = var.enabled ? 1 : 0

  name = "${var.cluster_name}-karpenter-rebalance"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  count = var.enabled ? 1 : 0

  name = "${var.cluster_name}-karpenter-instance-state"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "health_event" {
  count = var.enabled ? 1 : 0

  name = "${var.cluster_name}-karpenter-health"
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  count = var.enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.spot_interruption[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption[0].arn
}

resource "aws_cloudwatch_event_target" "rebalance" {
  count = var.enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.rebalance[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption[0].arn
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  count = var.enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.instance_state_change[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption[0].arn
}

resource "aws_cloudwatch_event_target" "health_event" {
  count = var.enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.health_event[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.interruption[0].arn
}

# ── Controller IRSA ───────────────────────────

data "aws_iam_policy_document" "controller_assume" {
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
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
  }
}

resource "aws_iam_role" "controller" {
  count = var.enabled ? 1 : 0

  name               = local.controller_role_name
  assume_role_policy = data.aws_iam_policy_document.controller_assume[0].json
  tags               = var.tags
}

# Scoped controller policy aligned with Karpenter CloudFormation reference.
data "aws_iam_policy_document" "controller" {
  count = var.enabled ? 1 : 0

  statement {
    sid    = "AllowScopedEC2InstanceAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}::image/*",
      "arn:${local.partition}:ec2:${local.region}::snapshot/*",
      "arn:${local.partition}:ec2:${local.region}:*:security-group/*",
      "arn:${local.partition}:ec2:${local.region}:*:subnet/*",
      "arn:${local.partition}:ec2:${local.region}:*:capacity-reservation/*",
      "arn:${local.partition}:ec2:${local.region}:*:placement-group/*",
    ]
  }

  statement {
    sid    = "AllowScopedEC2LaunchTemplateAccessActions"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedEC2InstanceActionsWithTags"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid     = "AllowScopedResourceCreationTagging"
    effect  = "Allow"
    actions = ["ec2:CreateTags"]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:fleet/*",
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:volume/*",
      "arn:${local.partition}:ec2:${local.region}:*:network-interface/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
      "arn:${local.partition}:ec2:${local.region}:*:spot-instances-request/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedResourceTagging"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:${local.region}:*:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
    }
  }

  statement {
    sid    = "AllowScopedDeletion"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]
    resources = [
      "arn:${local.partition}:ec2:${local.region}:*:instance/*",
      "arn:${local.partition}:ec2:${local.region}:*:launch-template/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.sh/nodepool"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowPassingInstanceRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.node[0].arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileCreationActions"
    effect    = "Allow"
    actions   = ["iam:CreateInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowScopedInstanceProfileTagActions"
    effect    = "Allow"
    actions   = ["iam:TagInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks:eks-cluster-name"
      values   = [var.cluster_name]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
    condition {
      test     = "StringLike"
      variable = "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid    = "AllowScopedInstanceProfileActions"
    effect = "Allow"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:DeleteInstanceProfile",
    ]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
      values   = ["owned"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/topology.kubernetes.io/region"
      values   = [local.region]
    }
    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass"
      values   = ["*"]
    }
  }

  statement {
    sid       = "AllowAPIServerEndpointDiscovery"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"]
  }

  statement {
    sid    = "AllowInterruptionQueueActions"
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.interruption[0].arn]
  }

  statement {
    sid       = "AllowRegionalReadActions"
    effect    = "Allow"
    resources = ["*"]
    actions = [
      "ec2:DescribeCapacityReservations",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribePlacementGroups",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }

  statement {
    sid       = "AllowSSMReadActions"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:${local.region}::parameter/aws/service/*"]
  }

  statement {
    sid       = "AllowPricingReadActions"
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowUnscopedInstanceProfileListAction"
    effect    = "Allow"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowInstanceProfileReadActions"
    effect    = "Allow"
    actions   = ["iam:GetInstanceProfile"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:instance-profile/*"]
  }
}

resource "aws_iam_policy" "controller" {
  count = var.enabled ? 1 : 0

  name        = "${var.cluster_name}-karpenter-controller"
  description = "Karpenter controller permissions for ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.controller[0].json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "controller" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.controller[0].name
  policy_arn = aws_iam_policy.controller[0].arn
}

# ── Helm: CRDs → controller → NodePool/EC2NodeClass ─
#
# kubernetes_manifest cannot plan against CRDs that do not exist yet
# (GVK lookup fails). Install CRDs via the official karpenter-crd
# chart, then apply Node resources with a local Helm chart so a
# single terraform apply works.

resource "helm_release" "karpenter_crd" {
  count = var.enabled && (var.install_helm || var.create_node_resources) ? 1 : 0

  name       = "karpenter-crd"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = var.chart_version
  namespace  = var.namespace

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  # CRDs are cluster-scoped; chart still expects a namespace for the release.
  depends_on = [
    aws_iam_role_policy_attachment.controller,
  ]
}

resource "helm_release" "karpenter" {
  count = var.enabled && var.install_helm ? 1 : 0

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.chart_version
  namespace  = var.namespace

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = aws_sqs_queue.interruption[0].name
      }
      serviceAccount = {
        create = true
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.controller[0].arn
        }
      }
      # Pin controller to critical MNG so it can recover when Spot/elastic nodes are empty.
      # Requires managed node groups labeled workload-class=critical (see docs/workload-placement.md).
      nodeSelector = {
        "workload-class" = "critical"
      }
      # Phase 2: add matching toleration when MNG is tainted workload-class=critical:NoSchedule.
      # tolerations = [{
      #   key      = "workload-class"
      #   operator = "Equal"
      #   value    = "critical"
      #   effect   = "NoSchedule"
      # }]
    })
  ]

  depends_on = [
    helm_release.karpenter_crd,
    aws_iam_role_policy_attachment.controller,
    aws_eks_access_entry.node,
    aws_sqs_queue_policy.interruption,
  ]
}

# EC2NodeClass + NodePool(s) via local chart (avoids kubernetes_manifest CRD race).
resource "helm_release" "node_resources" {
  count = var.enabled && var.create_node_resources ? 1 : 0

  name      = "karpenter-node-resources"
  chart     = "${path.module}/charts/node-resources"
  namespace = var.namespace

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  values = [
    yamlencode({
      ec2nodeclassName  = var.ec2nodeclass_name
      nodeRoleName      = aws_iam_role.node[0].name
      discoveryTagValue = local.discovery
      amiAlias          = var.ami_alias
      spotPreferred     = var.spot_preferred
      expireAfter       = var.expire_after
      consolidateAfter  = var.consolidate_after
      cpuLimit          = var.nodepool_cpu_limit
      memoryLimit       = var.nodepool_memory_limit
      maxPods           = var.node_max_pods
      nodepoolWeights = {
        spot     = var.nodepool_weights.spot
        onDemand = var.nodepool_weights.on_demand
      }
      disruptionBudgetNodes = {
        spot     = var.disruption_budget_nodes.spot
        onDemand = var.disruption_budget_nodes.on_demand
      }
      nodeTaints           = var.node_taints
      spotRequirements     = local.spot_requirements
      onDemandRequirements = local.on_demand_requirements
    })
  ]

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter,
  ]
}
