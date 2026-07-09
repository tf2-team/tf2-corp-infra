# ──────────────────────────────────────────────
# GitHub Actions OIDC → IAM role for ECR push
# ──────────────────────────────────────────────

locals {
  github_oidc_url  = "https://token.actions.githubusercontent.com"
  github_oidc_host = "token.actions.githubusercontent.com"

  environment_subjects = [
    for env in var.github_environments :
    "repo:${var.github_repository}:environment:${env}"
  ]

  ref_subjects = [
    for ref in var.allowed_refs :
    "repo:${var.github_repository}:ref:${ref}"
  ]

  allowed_subjects = concat(local.environment_subjects, local.ref_subjects)

  oidc_provider_arn = (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : (
      var.existing_oidc_provider_arn != null
      ? var.existing_oidc_provider_arn
      : data.aws_iam_openid_connect_provider.github[0].arn
    )
  )
}

# ──────────────────────────────────────────────
# GitHub OIDC provider (account-level singleton)
# ──────────────────────────────────────────────

data "tls_certificate" "github" {
  count = var.create_oidc_provider ? 1 : 0
  url   = local.github_oidc_url
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[length(data.tls_certificate.github[0].certificates) - 1].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "github-actions-oidc"
  })
}

data "aws_iam_openid_connect_provider" "github" {
  count = (!var.create_oidc_provider && var.existing_oidc_provider_arn == null) ? 1 : 0
  url   = local.github_oidc_url
}

# ──────────────────────────────────────────────
# Trust policy
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.github_oidc_host}:sub"
      values   = local.allowed_subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  description        = "GitHub Actions role for pushing container images to ECR (${var.github_repository})"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, {
    Name = var.name
  })

  lifecycle {
    precondition {
      condition     = var.create_oidc_provider ? var.existing_oidc_provider_arn == null : true
      error_message = "If create_oidc_provider is true, existing_oidc_provider_arn must be null."
    }
  }
}

# ──────────────────────────────────────────────
# ECR push permissions (least privilege)
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid    = "EcrAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:DescribeRepositories",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  name   = "${var.name}-ecr-push"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.ecr_push.json
}
