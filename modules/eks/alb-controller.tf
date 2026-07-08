# ──────────────────────────────────────────────
# Locals
# ──────────────────────────────────────────────

locals {
  cluster_issuer_url = aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_issuer_path   = replace(local.cluster_issuer_url, "https://", "")
  oidc_provider_arn  = var.create_oidc_provider ? aws_iam_openid_connect_provider.eks[0].arn : coalesce(var.existing_oidc_provider_arn, "arn:aws:iam::123456789012:oidc-provider/dummy")
}

# ──────────────────────────────────────────────
# TLS Certificate & EKS OIDC Provider
# ──────────────────────────────────────────────

data "tls_certificate" "eks" {
  count = var.create_oidc_provider ? 1 : 0
  url   = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = var.create_oidc_provider ? 1 : 0
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks[0].certificates[length(data.tls_certificate.eks[0].certificates) - 1].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_openid_connect_provider" "existing" {
  count = (!var.create_oidc_provider && var.existing_oidc_provider_arn != null) ? 1 : 0
  arn   = var.existing_oidc_provider_arn
}

# ──────────────────────────────────────────────
# IAM Policy for AWS Load Balancer Controller
# ──────────────────────────────────────────────

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name        = "${var.cluster_name}-alb-controller-policy"
  path        = "/"
  description = "IAM policy for AWS Load Balancer Controller on EKS cluster ${var.cluster_name}"
  policy      = file("${path.module}/iam-policy.json")
}

# ──────────────────────────────────────────────
# IAM Role & Attachment (IRSA)
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "aws_load_balancer_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [local.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.cluster_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume.json

  lifecycle {
    precondition {
      condition     = var.create_oidc_provider ? var.existing_oidc_provider_arn == null : var.existing_oidc_provider_arn != null
      error_message = "If create_oidc_provider is true, existing_oidc_provider_arn must be null. If create_oidc_provider is false, existing_oidc_provider_arn must be set."
    }

    precondition {
      condition     = var.create_oidc_provider ? true : (length(data.aws_iam_openid_connect_provider.existing) > 0 ? data.aws_iam_openid_connect_provider.existing[0].url == local.cluster_issuer_url : false)
      error_message = "The existing OIDC provider URL must match the EKS cluster issuer URL."
    }

    precondition {
      condition     = var.create_oidc_provider ? true : (length(data.aws_iam_openid_connect_provider.existing) > 0 ? contains(data.aws_iam_openid_connect_provider.existing[0].client_id_list, "sts.amazonaws.com") : false)
      error_message = "The existing OIDC provider client_id_list must contain 'sts.amazonaws.com'."
    }
  }
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
  role       = aws_iam_role.aws_load_balancer_controller.name
}


