# ──────────────────────────────────────────────
# IAM Policy cho External Secrets Operator (ESO)
# Chỉ cho phép đọc secret có prefix của cluster
# để đảm bảo least-privilege giữa các TF
# ──────────────────────────────────────────────

resource "aws_iam_policy" "eso" {
  name        = "${var.cluster_name}-eso-policy"
  path        = "/"
  description = "IAM policy for External Secrets Operator on EKS cluster ${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        # Chỉ đọc được secret có prefix = tên cluster
        # vd: techx-tf2/postgres-credentials
        #     techx-tf2/grafana-admin
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.cluster_name}/*"
      }
    ]
  })
}

# ──────────────────────────────────────────────
# Trust Policy: chỉ ServiceAccount
# "external-secrets" trong namespace
# "external-secrets" được phép assume role
# (IRSA - IAM Roles for Service Accounts)
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
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

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-eso-role"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json

  tags = {
    Description = "IRSA role for External Secrets Operator - allows reading Secrets Manager secrets prefixed with ${var.cluster_name}/"
  }
}

resource "aws_iam_role_policy_attachment" "eso" {
  policy_arn = aws_iam_policy.eso.arn
  role       = aws_iam_role.eso.name
}
