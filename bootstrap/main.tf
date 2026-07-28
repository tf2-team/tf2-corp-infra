data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project_name}-tf-state-${local.account_id}-${var.aws_region}"
}

# ──────────────────────────────────────────────
# KMS Key configuration for S3 State Encryption
# ──────────────────────────────────────────────

resource "aws_kms_key" "state_key" {
  description             = "KMS Key for Terraform State S3 Bucket"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-tf-state-key"
  }
}

resource "aws_kms_alias" "state_key_alias" {
  name          = "alias/${var.project_name}-tf-state-key"
  target_key_id = aws_kms_key.state_key.key_id
}

# ──────────────────────────────────────────────
# S3 State Bucket configuration
# ──────────────────────────────────────────────

resource "aws_s3_bucket" "state_bucket" {
  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.bucket_name
  }
}

# Enable Versioning
resource "aws_s3_bucket_versioning" "state_bucket_versioning" {
  bucket = aws_s3_bucket.state_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block Public Access
resource "aws_s3_bucket_public_access_block" "state_bucket_public_access" {
  bucket = aws_s3_bucket.state_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce Bucket Owner Controls (disable ACLs)
resource "aws_s3_bucket_ownership_controls" "state_bucket_ownership" {
  bucket = aws_s3_bucket.state_bucket.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Server-Side Encryption (SSE-KMS) with Bucket Key
resource "aws_s3_bucket_server_side_encryption_configuration" "state_bucket_encryption" {
  bucket = aws_s3_bucket.state_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.state_key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Enforce TLS-only requests
resource "aws_s3_bucket_policy" "state_bucket_policy" {
  bucket = aws_s3_bucket.state_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state_bucket.arn,
          "${aws_s3_bucket.state_bucket.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state_bucket_public_access]
}

# Lifecycle Retention Policy
resource "aws_s3_bucket_lifecycle_configuration" "state_bucket_lifecycle" {
  bucket = aws_s3_bucket.state_bucket.id

  rule {
    id     = "terraform-state-retention"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ──────────────────────────────────────────────
# KMS Key configuration for Cosign Image Signing
# ──────────────────────────────────────────────

resource "aws_kms_key" "cosign" {
  description              = "TF2 Cosign image signing key"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 7

  tags = merge(var.tags, {
    Purpose = "cosign-image-signing"
    Mandate = "MD10"
  })
}

resource "aws_kms_alias" "cosign" {
  name          = "alias/tf2-cosign-signing-key"
  target_key_id = aws_kms_key.cosign.key_id
}

# ──────────────────────────────────────────────
# GitHub Actions OIDC (account-level singleton)
# + ECR push roles for platform CI/CD
# ──────────────────────────────────────────────

locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"

  # Nested ECR project prefixes (repos created later by environment stacks).
  # Wildcard ARNs avoid depending on environment module outputs.
  #
  # AI models buckets use the env stack naming contract:
  #   ${project_name}-ai-models-${account_id}
  # Mem0 IRSA (env stack) only allows GetObject under the FastEmbed prefix;
  # CI must publish under the same prefix or fetch-mem0-fastembed gets 403.
  mem0_fastembed_prefix = "fastembed/paraphrase-multilingual-MiniLM-L12-v2"
  ai_models_buckets = {
    production  = "techx-prod-tf2-ai-models-${local.account_id}"
    development = "techx-dev-tf2-ai-models-${local.account_id}"
  }

  github_actions_ecr_roles = {
    production = {
      name                = var.github_actions_ecr_production.role_name
      github_repository   = var.github_actions_ecr_production.github_repository
      github_environments = var.github_actions_ecr_production.github_environments
      allowed_refs        = var.github_actions_ecr_production.allowed_refs
      ecr_repository_arns = [
        "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.github_actions_ecr_production.ecr_project_name}/*",
      ]
      s3_publish_bucket_arns = [
        "arn:aws:s3:::${local.ai_models_buckets.production}",
      ]
      s3_publish_object_arns = [
        "arn:aws:s3:::${local.ai_models_buckets.production}/${local.mem0_fastembed_prefix}/*",
      ]
      s3_publish_list_prefixes = [
        "${local.mem0_fastembed_prefix}/*",
      ]
      lambda_update_function_arns = [
        "arn:aws:lambda:${var.aws_region}:${local.account_id}:function:techx-audit-alert-router",
      ]
    }
    development = {
      name                = var.github_actions_ecr_development.role_name
      github_repository   = var.github_actions_ecr_development.github_repository
      github_environments = var.github_actions_ecr_development.github_environments
      allowed_refs        = var.github_actions_ecr_development.allowed_refs
      ecr_repository_arns = [
        "arn:aws:ecr:${var.aws_region}:${local.account_id}:repository/${var.github_actions_ecr_development.ecr_project_name}/*",
      ]
      s3_publish_bucket_arns = [
        "arn:aws:s3:::${local.ai_models_buckets.development}",
      ]
      s3_publish_object_arns = [
        "arn:aws:s3:::${local.ai_models_buckets.development}/${local.mem0_fastembed_prefix}/*",
      ]
      s3_publish_list_prefixes = [
        "${local.mem0_fastembed_prefix}/*",
      ]
    }
  }
}

data "tls_certificate" "github" {
  url = local.github_oidc_url
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[length(data.tls_certificate.github.certificates) - 1].sha1_fingerprint]

  tags = merge(var.tags, {
    Name = "github-actions-oidc"
  })
}

module "github_actions_ecr" {
  source   = "../modules/github-actions-ecr"
  for_each = local.github_actions_ecr_roles

  name                = each.value.name
  github_repository   = each.value.github_repository
  github_environments = each.value.github_environments
  allowed_refs        = each.value.allowed_refs
  oidc_provider_arn   = aws_iam_openid_connect_provider.github.arn
  ecr_repository_arns = each.value.ecr_repository_arns

  s3_publish_bucket_arns   = each.value.s3_publish_bucket_arns
  s3_publish_object_arns   = each.value.s3_publish_object_arns
  s3_publish_list_prefixes = each.value.s3_publish_list_prefixes
  lambda_update_function_arns = lookup(each.value, "lambda_update_function_arns", [])
  cosign_kms_key_arn       = aws_kms_key.cosign.arn

  tags = merge(var.tags, {
    Purpose = "github-actions-ecr-push"
    Scope   = each.key
  })
}

# ──────────────────────────────────────────────
# GitHub Actions OIDC → Terraform plan/apply roles
# (infra repository CI/CD — operator secrets in GitHub)
# ──────────────────────────────────────────────

locals {
  github_actions_terraform_roles = {
    "development-plan" = {
      name              = var.github_actions_terraform_development.plan_role_name
      github_repository = var.github_actions_terraform_development.github_repository
      # Plan jobs attach GitHub Environment `dev` for secrets → OIDC sub environment:dev
      github_environments = [
        var.github_actions_terraform_development.apply_github_environment,
      ]
      allowed_refs       = var.github_actions_terraform_development.plan_allowed_refs
      allow_pull_request = var.github_actions_terraform_development.plan_allow_pull_request
      permission_level   = "plan"
      state_key_prefixes = [var.github_actions_terraform_development.state_key_prefix]
      iam_name_prefixes  = []
      description        = "GitHub Actions Terraform plan role for development (${var.github_actions_terraform_development.github_repository})"
    }
    "development-apply" = {
      name              = var.github_actions_terraform_development.apply_role_name
      github_repository = var.github_actions_terraform_development.github_repository
      github_environments = [
        var.github_actions_terraform_development.apply_github_environment,
      ]
      allowed_refs       = []
      allow_pull_request = false
      permission_level   = "apply"
      state_key_prefixes = [var.github_actions_terraform_development.state_key_prefix]
      iam_name_prefixes  = var.github_actions_terraform_development.iam_name_prefixes
      description        = "GitHub Actions Terraform apply role for development (Environment ${var.github_actions_terraform_development.apply_github_environment})"
    }
    "production-plan" = {
      name              = var.github_actions_terraform_production.plan_role_name
      github_repository = var.github_actions_terraform_production.github_repository
      # Production plan jobs intentionally omit GitHub Environment (required reviewers
      # on `production` only gate apply). Trust stays ref + pull_request subjects.
      github_environments = []
      allowed_refs        = var.github_actions_terraform_production.plan_allowed_refs
      allow_pull_request  = var.github_actions_terraform_production.plan_allow_pull_request
      permission_level    = "plan"
      state_key_prefixes  = [var.github_actions_terraform_production.state_key_prefix]
      iam_name_prefixes   = []
      description         = "GitHub Actions Terraform plan role for production (${var.github_actions_terraform_production.github_repository})"
    }
    "production-apply" = {
      name              = var.github_actions_terraform_production.apply_role_name
      github_repository = var.github_actions_terraform_production.github_repository
      github_environments = [
        var.github_actions_terraform_production.apply_github_environment,
      ]
      allowed_refs       = []
      allow_pull_request = false
      permission_level   = "apply"
      state_key_prefixes = [var.github_actions_terraform_production.state_key_prefix]
      iam_name_prefixes  = var.github_actions_terraform_production.iam_name_prefixes
      description        = "GitHub Actions Terraform apply role for production (Environment ${var.github_actions_terraform_production.apply_github_environment})"
    }
  }
}

module "github_actions_terraform" {
  source   = "../modules/github-actions-terraform"
  for_each = local.github_actions_terraform_roles

  name                               = each.value.name
  description                        = each.value.description
  github_repository                  = each.value.github_repository
  github_environments                = each.value.github_environments
  allowed_refs                       = each.value.allowed_refs
  allow_pull_request                 = each.value.allow_pull_request
  oidc_provider_arn                  = aws_iam_openid_connect_provider.github.arn
  permission_level                   = each.value.permission_level
  state_bucket_arn                   = aws_s3_bucket.state_bucket.arn
  state_kms_key_arn                  = aws_kms_key.state_key.arn
  state_key_prefixes                 = each.value.state_key_prefixes
  iam_name_prefixes                  = each.value.iam_name_prefixes
  enforce_managed_policy_exclusivity = each.key == "production-apply"

  tags = merge(var.tags, {
    Purpose = "github-actions-terraform"
    Scope   = each.key
  })
}

# ──────────────────────────────────────────────
# Mandate 21: FIS Execution Role (production environment)
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "fis_prod_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:fis:${var.aws_region}:${local.account_id}:experiment-template/*"]
    }
  }
}

resource "aws_iam_role" "fis_prod" {
  name               = "${var.project_name}-prod-tf2-fis-execution-role"
  assume_role_policy = data.aws_iam_policy_document.fis_prod_assume_role.json

  tags = merge(var.tags, {
    Name    = "${var.project_name}-prod-tf2-fis-execution-role"
    Mandate = "MD21"
    Purpose = "fis-execution-role"
  })
}

data "aws_iam_policy_document" "fis_prod_policy" {
  #checkov:skip=CKV_AWS_111:FIS fault injection requires EC2 NACL manipulation, S3 logging, and KMS key actions for dynamic fault targets.
  #checkov:skip=CKV_AWS_356:FIS experiment actions use account-scoped wildcard resources for dynamic EC2 subnet NACLs, S3 evidence logging, and KMS keys.

  statement {
    sid    = "AllowEC2InstanceActions"
    effect = "Allow"
    actions = [
      "ec2:StopInstances",
      "ec2:StartInstances",
    ]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*"
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/kubernetes.io/cluster/techx-tf2-prod"
      values   = ["shared"]
    }
  }

  statement {
    sid    = "AllowEC2ReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeNetworkAcls",
      "ec2:DescribeManagedPrefixLists",
      "ec2:GetManagedPrefixListEntries",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowNACLDisruptionActions"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkAcl",
      "ec2:CreateNetworkAclEntry",
      "ec2:CreateTags",
      "ec2:DeleteNetworkAcl",
      "ec2:DeleteNetworkAclEntry",
      "ec2:ReplaceNetworkAclAssociation",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/managedByFIS"
      values   = ["true"]
    }
  }

  statement {
    sid       = "AllowRDSFailoverActions"
    effect    = "Allow"
    actions   = ["rds:RebootDBInstance"]
    resources = ["arn:aws:rds:${var.aws_region}:${local.account_id}:db:techx-prod-tf2-postgresql"]
  }

  statement {
    sid       = "AllowRDSReadActions"
    effect    = "Allow"
    actions   = ["rds:DescribeDBInstances"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowValkeyFailoverActions"
    effect    = "Allow"
    actions   = ["elasticache:InterruptClusterAzPower"]
    resources = ["arn:aws:elasticache:${var.aws_region}:${local.account_id}:replicationgroup:techx-prod-tf2-cart"]
  }

  statement {
    sid       = "AllowValkeyReadActions"
    effect    = "Allow"
    actions   = ["elasticache:DescribeReplicationGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "AllowFISTargetResolutionByTags"
    effect    = "Allow"
    actions   = ["tag:GetResources"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowS3EvidenceLogging"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:aws:s3:::techx-prod-tf2-immutable-audit-${local.account_id}",
      "arn:aws:s3:::techx-prod-tf2-immutable-audit-${local.account_id}/mandate-21/fis/*",
    ]
  }

  statement {
    sid    = "AllowKMSEvidenceEncryption"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt",
    ]
    resources = [
      "arn:aws:kms:${var.aws_region}:${local.account_id}:key/*",
    ]
  }

  statement {
    sid       = "AllowEncryptedEC2RestartGrant"
    effect    = "Allow"
    actions   = ["kms:CreateGrant"]
    resources = ["arn:aws:kms:${var.aws_region}:${local.account_id}:key/*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ec2.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "fis_prod" {
  name   = "${var.project_name}-prod-tf2-fis-policy"
  role   = aws_iam_role.fis_prod.id
  policy = data.aws_iam_policy_document.fis_prod_policy.json
}

# Change trail: @hungxqt - 2026-07-28 - Completed least-required permissions for Mandate 21 FIS actions.
