# ──────────────────────────────────────────────
# EBS CSI Driver IRSA
#
# Controller pods call EC2 APIs (CreateVolume, Describe*, etc.).
# Without service_account_role_arn on the managed addon they fall back to
# IMDS / instance profile. On many EKS node AMIs (IMDSv2 hop limit = 1)
# that fails with:
#   no EC2 IMDS role found / ec2imds GetMetadata context deadline exceeded
#
# IRSA is the supported fix: trust ebs-csi-controller-sa + managed policy.
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "ebs_csi_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
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

resource "aws_iam_role" "ebs_csi_controller" {
  name               = "${var.cluster_name}-ebs-csi-controller-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_controller_assume.json

  lifecycle {
    precondition {
      condition     = var.create_oidc_provider ? var.existing_oidc_provider_arn == null : var.existing_oidc_provider_arn != null
      error_message = "If create_oidc_provider is true, existing_oidc_provider_arn must be null. If create_oidc_provider is false, existing_oidc_provider_arn must be set."
    }
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_controller" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_controller.name
}
