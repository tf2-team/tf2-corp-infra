# ──────────────────────────────────────────────
# GitHub Actions OIDC → IAM role for Terraform plan/apply
# OIDC provider is account-level and owned by bootstrap.
# ──────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  account_id       = data.aws_caller_identity.current.account_id
  partition        = data.aws_partition.current.partition

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
  # apply: PowerUser (non-IAM AWS APIs) + custom prefix-scoped IAM (below) + state.
  # Do not attach IAMFullAccess (CKV2_AWS_56) — env modules only need IAM for
  # roles/policies/instance-profiles named under iam_name_prefixes.
  managed_policy_arns = var.permission_level == "plan" ? [
    "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess",
    ] : [
    "arn:${local.partition}:iam::aws:policy/PowerUserAccess",
  ]

  iam_role_arns = [
    for p in var.iam_name_prefixes :
    "arn:${local.partition}:iam::${local.account_id}:role/${p}*"
  ]

  iam_policy_arns = [
    for p in var.iam_name_prefixes :
    "arn:${local.partition}:iam::${local.account_id}:policy/${p}*"
  ]

  iam_instance_profile_arns = [
    for p in var.iam_name_prefixes :
    "arn:${local.partition}:iam::${local.account_id}:instance-profile/${p}*"
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

check "apply_iam_prefixes" {
  assert {
    condition     = var.permission_level != "apply" || length(var.iam_name_prefixes) > 0
    error_message = "permission_level=apply requires at least one iam_name_prefixes entry (role/policy name prefixes created by env stacks)."
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
# Apply-only IAM: least privilege for Terraform-managed identities
# Replaces AWS managed IAMFullAccess (CKV2_AWS_56).
# Scoped to iam_name_prefixes (e.g. techx-dev-, techx-tf2-prod-).
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "terraform_iam" {
  count = var.permission_level == "apply" ? 1 : 0

  # Account-level discovery used by Terraform IAM data sources / plan refresh.
  # These APIs do not support resource-level ARNs.
  # checkov:skip=CKV_AWS_356:IAM List/Get discovery APIs require Resource=*
  statement {
    sid    = "IamReadListAccount"
    effect = "Allow"
    actions = [
      "iam:GetAccountSummary",
      "iam:ListAccountAliases",
      "iam:ListRoles",
      "iam:ListPolicies",
      "iam:ListInstanceProfiles",
      "iam:ListOpenIDConnectProviders",
      "iam:GetOpenIDConnectProvider",
    ]
    resources = ["*"]
  }

  # Roles created by env modules: EKS cluster/node, ALB, EBS CSI, ESO,
  # cluster-autoscaler, Karpenter controller/node, etc.
  statement {
    sid    = "IamManageRolesByPrefix"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateRoleDescription",
      "iam:UpdateAssumeRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRoleTags",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
    ]
    resources = local.iam_role_arns
  }

  # Customer-managed policies (ALB controller, ESO, CA, Karpenter controller, …)
  statement {
    sid    = "IamManagePoliciesByPrefix"
    effect = "Allow"
    actions = [
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:SetDefaultPolicyVersion",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListPolicyTags",
      "iam:TagPolicy",
      "iam:UntagPolicy",
    ]
    resources = local.iam_policy_arns
  }

  # Read AWS managed policies attached by modules (EKS, CNI, ECR RO, EBS CSI, SSM, …)
  statement {
    sid    = "IamReadAwsManagedPolicies"
    effect = "Allow"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:ListPolicyVersions",
    ]
    resources = [
      "arn:${local.partition}:iam::aws:policy/*",
    ]
  }

  # Instance profiles for node roles / Karpenter-related names under the same prefixes
  statement {
    sid    = "IamManageInstanceProfilesByPrefix"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:UntagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:ListInstanceProfileTags",
    ]
    resources = local.iam_instance_profile_arns
  }

  # EKS IRSA OIDC providers (issuer URL is cluster-specific; ARN is not name-prefixed)
  statement {
    sid    = "IamManageOidcProviders"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviderTags",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:oidc-provider/*",
    ]
  }

  # Service-linked roles required by EKS, ELB, Auto Scaling, etc.
  statement {
    sid    = "IamServiceLinkedRoles"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
      "iam:DeleteServiceLinkedRole",
      "iam:GetServiceLinkedRoleDeletionStatus",
    ]
    resources = [
      "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/*",
    ]
  }
}

resource "aws_iam_role_policy" "terraform_iam" {
  count = var.permission_level == "apply" ? 1 : 0

  name   = "${var.name}-terraform-iam"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.terraform_iam[0].json
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
