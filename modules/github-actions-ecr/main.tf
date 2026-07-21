# ──────────────────────────────────────────────
# GitHub Actions OIDC → IAM role for ECR push
# OIDC provider is account-level and owned by bootstrap.
# ──────────────────────────────────────────────

locals {
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
      identifiers = [var.oidc_provider_arn]
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

# Optional: publish Mem0 FastEmbed (or other model caches) to the AI models bucket.
# Platform CI uses the same OIDC role as ECR push (vars.AWS_ROLE_ARN).
data "aws_iam_policy_document" "s3_publish" {
  count = length(var.s3_publish_bucket_arns) > 0 ? 1 : 0

  statement {
    sid    = "ListModelArtifactPrefixes"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = var.s3_publish_bucket_arns
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = var.s3_publish_list_prefixes
    }
  }

  statement {
    sid    = "ReadWriteModelArtifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = var.s3_publish_object_arns
  }
}

resource "aws_iam_role_policy" "s3_publish" {
  count = length(var.s3_publish_bucket_arns) > 0 ? 1 : 0

  name   = "${var.name}-s3-model-publish"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.s3_publish[0].json
}

data "aws_iam_policy_document" "kms_signing" {
  count = var.cosign_kms_key_arn != "" ? 1 : 0

  statement {
    sid    = "KmsCosignSign"
    effect = "Allow"
    actions = [
      "kms:Sign",
      "kms:GetPublicKey",
      "kms:DescribeKey"
    ]
    resources = [var.cosign_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "kms_signing" {
  count  = var.cosign_kms_key_arn != "" ? 1 : 0
  name   = "${var.name}-kms-signing"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.kms_signing[0].json
}
# Change trail: @hungxqt - 2026-07-19 - Grant optional S3 model publish to platform GHA ECR roles.
