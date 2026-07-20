# ──────────────────────────────────────────────
# MANDATE 10: Sigstore policy-controller — IRSA only.
#
# Deployment/ClusterImagePolicy manifests are owned by tf2-corp-chart
# (gitops/supply-chain, Kustomize). This module only provisions the
# read-only IAM identity the controller's ServiceAccount assumes to:
#   - fetch the Cosign public key from KMS (verify signatures; never sign)
#   - pull image manifests/signature layers from ECR (verify-only)
# ──────────────────────────────────────────────

locals {
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")
  sa_subject        = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}

data "aws_iam_policy_document" "assume" {
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

resource "aws_iam_role" "this" {
  count = var.enabled ? 1 : 0

  name               = "${var.cluster_name}-policy-controller"
  description        = "IRSA role for Sigstore policy-controller (Cosign signature verification, read-only)"
  assume_role_policy = data.aws_iam_policy_document.assume[0].json
  tags               = merge(var.tags, { Name = "${var.cluster_name}-policy-controller" })
}

data "aws_iam_policy_document" "verify" {
  count = var.enabled ? 1 : 0

  statement {
    sid    = "KmsCosignVerify"
    effect = "Allow"
    actions = [
      "kms:GetPublicKey",
      "kms:DescribeKey",
    ]
    resources = [var.cosign_kms_key_arn]
  }

  statement {
    sid    = "EcrAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPullOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "verify" {
  count = var.enabled ? 1 : 0

  name   = "${var.cluster_name}-policy-controller-verify"
  role   = aws_iam_role.this[0].id
  policy = data.aws_iam_policy_document.verify[0].json
}
