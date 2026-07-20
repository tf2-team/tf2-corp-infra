data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Preserve the existing product-reviews IAM resources while the module moves
# from a single hard-coded consumer to the multi-consumer map.
moved {
  from = aws_iam_policy.model_read
  to   = aws_iam_policy.model_read["product-reviews"]
}

moved {
  from = aws_iam_role.model_read
  to   = aws_iam_role.model_read["product-reviews"]
}

moved {
  from = aws_iam_role_policy_attachment.model_read
  to   = aws_iam_role_policy_attachment.model_read["product-reviews"]
}

locals {
  bucket_name      = "${var.name}-ai-models-${data.aws_caller_identity.current.account_id}"
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")

  # System inference profiles use a geo/global prefix (global., us., eu., apac.).
  # Bedrock still authorizes InvokeModel against the underlying foundation model id.
  bedrock_foundation_model_ids = {
    for name, consumer in var.consumers : name => distinct([
      for profile_id in consumer.bedrock_inference_profile_ids :
      (
        startswith(profile_id, "global.") ? trimprefix(profile_id, "global.") :
        startswith(profile_id, "us.") ? trimprefix(profile_id, "us.") :
        startswith(profile_id, "eu.") ? trimprefix(profile_id, "eu.") :
        startswith(profile_id, "apac.") ? trimprefix(profile_id, "apac.") :
        profile_id
      )
    ])
  }

  consumer_access_contracts = {
    for name, consumer in var.consumers : name => {
      role_name                     = "${var.name}-${name}-model-read"
      service_account_subject       = "system:serviceaccount:${consumer.namespace}:${consumer.service_account_name}"
      model_prefix                  = consumer.model_prefix
      object_arn                    = "${aws_s3_bucket.models.arn}/${consumer.model_prefix}*"
      allow_list_bucket             = consumer.allow_list_bucket
      bedrock_inference_profile_ids = consumer.bedrock_inference_profile_ids
      bedrock_foundation_model_ids  = local.bedrock_foundation_model_ids[name]
    }
  }
}

resource "aws_s3_bucket" "models" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "models" {
  bucket = aws_s3_bucket.models.id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    # Keeps stale multipart uploads from accumulating storage cost.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = "alias/aws/s3"
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.models.arn,
      "${aws_s3_bucket.models.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "models" {
  bucket = aws_s3_bucket.models.id
  policy = data.aws_iam_policy_document.bucket.json
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids
  tags              = var.tags
}

data "aws_iam_policy_document" "model_read" {
  for_each = var.consumers

  statement {
    sid       = "ReadPinnedModelArtifacts"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.consumer_access_contracts[each.key].object_arn]
  }

  dynamic "statement" {
    for_each = each.value.allow_list_bucket ? [true] : []

    content {
      sid       = "ListPinnedModelPrefix"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.models.arn]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["${each.value.model_prefix}*"]
      }
    }
  }

  dynamic "statement" {
    for_each = contains(keys(var.database_iam_auth), each.key) ? [var.database_iam_auth[each.key]] : []

    content {
      sid       = "ConnectToMem0PostgresWithIam"
      effect    = "Allow"
      actions   = ["rds-db:connect"]
      resources = ["arn:${data.aws_partition.current.partition}:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${statement.value.db_resource_id}/${statement.value.database_user}"]
    }
  }

  dynamic "statement" {
    for_each = length(each.value.bedrock_inference_profile_ids) > 0 ? [true] : []

    content {
      sid    = "InvokeBedrockInferenceProfiles"
      effect = "Allow"
      actions = [
        "bedrock:GetInferenceProfile",
        "bedrock:InvokeModel",
      ]
      resources = [
        for profile_id in each.value.bedrock_inference_profile_ids :
        "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${profile_id}"
      ]
    }
  }

  # Inference profiles require InvokeModel on both the profile and the routed
  # foundation model ARNs. Condition keeps direct foundation-model invokes denied.
  dynamic "statement" {
    for_each = length(each.value.bedrock_inference_profile_ids) > 0 ? [true] : []

    content {
      sid     = "InvokeBedrockFoundationModelsViaProfiles"
      effect  = "Allow"
      actions = ["bedrock:InvokeModel"]
      resources = distinct(flatten([
        for model_id in local.bedrock_foundation_model_ids[each.key] : [
          "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}::foundation-model/${model_id}",
          "arn:${data.aws_partition.current.partition}:bedrock:::foundation-model/${model_id}",
        ]
      ]))
      condition {
        test     = "StringEquals"
        variable = "bedrock:InferenceProfileArn"
        values = [
          for profile_id in each.value.bedrock_inference_profile_ids :
          "arn:${data.aws_partition.current.partition}:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${profile_id}"
        ]
      }
    }
  }
}

resource "aws_iam_policy" "model_read" {
  for_each = var.consumers

  name   = local.consumer_access_contracts[each.key].role_name
  policy = data.aws_iam_policy_document.model_read[each.key].json
  tags   = var.tags
}

data "aws_iam_policy_document" "assume" {
  for_each = var.consumers

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:sub"
      values   = [local.consumer_access_contracts[each.key].service_account_subject]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "model_read" {
  for_each = var.consumers

  name               = local.consumer_access_contracts[each.key].role_name
  assume_role_policy = data.aws_iam_policy_document.assume[each.key].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "model_read" {
  for_each = var.consumers

  role       = aws_iam_role.model_read[each.key].name
  policy_arn = aws_iam_policy.model_read[each.key].arn
}

# Change trail: @hungxqt - 2026-07-20 - Allow Bedrock foundation-model InvokeModel via approved inference profiles.
