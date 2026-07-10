# ──────────────────────────────────────────────
# External Secrets Operator — IRSA + optional Helm
#
# IAM: GetSecretValue + DescribeSecret on exact ARNs only (no ListSecrets).
# Values never come from Terraform; ESO reads ASM via IRSA.
# ──────────────────────────────────────────────

locals {
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")
  sa_subject       = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
}

# ── IAM policy (least privilege) ──────────────

data "aws_iam_policy_document" "eso_secrets" {
  count = var.enabled ? 1 : 0

  statement {
    sid    = "SecretsManagerReadExact"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = var.secret_arns
  }
}

resource "aws_iam_policy" "eso" {
  count = var.enabled ? 1 : 0

  name        = "${var.cluster_name}-external-secrets-policy"
  path        = "/"
  description = "ESO read access to TechX ASM secrets (exact ARNs)"
  policy      = data.aws_iam_policy_document.eso_secrets[0].json
  tags        = var.tags
}

# ── IRSA trust ────────────────────────────────

data "aws_iam_policy_document" "eso_assume" {
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

resource "aws_iam_role" "eso" {
  count = var.enabled ? 1 : 0

  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.eso_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "eso" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.eso[0].name
  policy_arn = aws_iam_policy.eso[0].arn
}

# ── Optional: install ESO Helm chart ──────────

resource "kubernetes_namespace" "eso" {
  count = var.enabled && var.install_helm ? 1 : 0

  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "external-secrets"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "eso" {
  count = var.enabled && var.install_helm ? 1 : 0

  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.chart_version
  namespace  = kubernetes_namespace.eso[0].metadata[0].name

  create_namespace = false
  wait             = true
  atomic           = true
  timeout          = var.timeout_seconds

  values = [
    yamlencode({
      installCRDs = true
      serviceAccount = {
        create = true
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.eso[0].arn
        }
      }
      # Pin operator to critical MNG (docs/workload-placement.md).
      nodeSelector = {
        "workload-class" = "critical"
      }
      webhook = {
        nodeSelector = {
          "workload-class" = "critical"
        }
      }
      certController = {
        nodeSelector = {
          "workload-class" = "critical"
        }
      }
    })
  ]

  depends_on = [aws_iam_role_policy_attachment.eso]
}

# ── Optional: ClusterSecretStore (JWT / IRSA) ─

resource "kubernetes_manifest" "cluster_secret_store" {
  count = var.enabled && var.create_cluster_secret_store ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = var.cluster_secret_store_name
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = var.service_account_name
                namespace = var.namespace
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.eso]
}
