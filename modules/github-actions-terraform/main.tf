# ──────────────────────────────────────────────
# GitHub Actions OIDC → IAM role for Terraform plan/apply
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

  pull_request_subjects = var.allow_pull_request ? [
    "repo:${var.github_repository}:pull_request"
  ] : []

  allowed_subjects = concat(
    local.environment_subjects,
    local.ref_subjects,
    local.pull_request_subjects,
  )

  state_object_arns = [
    for prefix in var.state_key_prefixes :
    "${var.state_bucket_arn}/${prefix}*"
  ]

  # Managed policies by permission level.
  # plan: broad read for terraform refresh/plan + explicit state write for locks.
  # apply: PowerUser (most AWS APIs) + IAM (roles/policies created by modules) + state.
  managed_policy_arns = var.permission_level == "plan" ? [
    "arn:aws:iam::aws:policy/ReadOnlyAccess",
    ] : [
    "arn:aws:iam::aws:policy/PowerUserAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
  ]
}

# ──────────────────────────────────────────────
# Trust policy
# ──────────────────────────────────────────────

check "subjects_non_empty" {
  assert {
    condition     = length(local.allowed_subjects) > 0
    error_message = "At least one OIDC subject is required (github_environments, allowed_refs, and/or allow_pull_request)."
  }
}

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
  name                 = var.name
  description          = coalesce(var.description, "GitHub Actions Terraform ${var.permission_level} role (${var.github_repository})")
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration

  tags = merge(var.tags, {
    Name             = var.name
    PermissionLevel  = var.permission_level
    GitHubRepository = var.github_repository
  })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(local.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

# ──────────────────────────────────────────────
# Terraform remote state (S3 + KMS) — required for plan and apply
# Prefix-scoped so dev roles cannot read/write production state keys.
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid    = "TerraformStateListBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
    ]
    resources = [var.state_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for p in var.state_key_prefixes : "${p}*"]
    }
  }

  # S3 native lock files and state objects under the env prefix(es).
  statement {
    sid    = "TerraformStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = local.state_object_arns
  }

  statement {
    sid    = "TerraformStateKms"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = [var.state_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "terraform_state" {
  name   = "${var.name}-terraform-state"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.terraform_state.json
}
