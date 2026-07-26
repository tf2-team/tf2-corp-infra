# ──────────────────────────────────────────────
# CloudWatch metrics exporter (YACE) — IRSA only
#
# IAM: read-only CloudWatch metric APIs. The exporter uses static jobs
# (fixed dimension tuples), so tag:GetResources is intentionally omitted.
# CloudWatch metric APIs do not support resource-level scoping.
# The workload itself is deployed by techx-corp-chart (components.yace);
# this module only provides the IAM role the ServiceAccount assumes.
# ──────────────────────────────────────────────

locals {
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")
  sa_subject       = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}

data "aws_iam_policy_document" "cloudwatch_read" {
  statement {
    sid    = "CloudWatchMetricsReadOnly"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "this" {
  name        = "${var.name}-yace-cloudwatch-read-policy"
  path        = "/"
  description = "Read-only CloudWatch metrics access for the YACE exporter"
  policy      = data.aws_iam_policy_document.cloudwatch_read.json
  tags        = var.tags
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

resource "aws_iam_role" "this" {
  name               = "${var.name}-yace-cloudwatch-read"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}

# Change trail: @hungxqt - 2026-07-26 - IRSA role for YACE CloudWatch read-only metrics access.
