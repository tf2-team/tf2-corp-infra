# ──────────────────────────────────────────────
# TLS Certificate & EKS OIDC Provider
# ──────────────────────────────────────────────

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[length(data.tls_certificate.eks.certificates) - 1].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
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
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.cluster_name}-alb-controller-role"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume.json
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
  role       = aws_iam_role.aws_load_balancer_controller.name
}
