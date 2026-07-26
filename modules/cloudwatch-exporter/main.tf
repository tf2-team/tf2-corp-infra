locals {
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")
  sa_subject       = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}

data "aws_iam_policy_document" "assume" {
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

data "aws_iam_policy_document" "cloudwatch_read" {
  statement {
    sid    = "CloudWatchMetricRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-yace-cloudwatch-read"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "cloudwatch_read" {
  name   = "cloudwatch-metric-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.cloudwatch_read.json
}

# Change trail: AIO4 - 2026-07-26 - Add least-privilege YACE CloudWatch metric-read IRSA role.
