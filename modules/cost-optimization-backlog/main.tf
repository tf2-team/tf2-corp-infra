data "aws_caller_identity" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_region" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = var.enabled ? 1 : 0
}

locals {
  create = var.enabled

  account_id = local.create ? data.aws_caller_identity.current[0].account_id : "000000000000"
  region     = local.create ? data.aws_region.current[0].name : "us-east-1"
  partition  = local.create ? data.aws_partition.current[0].partition : "aws"

  kms_alias_name = "alias/${var.name_prefix}-cost-optimization-backlog"
  crawler_name   = coalesce(var.crawler_name, "${var.name_prefix}-cost-optimization-backlog")
  export_s3_path = "s3://${var.bucket_name}/${var.s3_prefix}/${var.export_name}/data/"
}

data "aws_iam_policy_document" "kms" {
  count = local.create ? 1 : 0

  statement {
    sid    = "EnableAccountKeyAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowBCMDataExportsEncrypt"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "billingreports.amazonaws.com",
        "bcm-data-exports.amazonaws.com",
      ]
    }

    actions = [
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${local.partition}:cur:us-east-1:${local.account_id}:definition/*",
        "arn:${local.partition}:bcm-data-exports:us-east-1:${local.account_id}:export/*",
      ]
    }
  }
}

resource "aws_kms_key" "this" {
  count = local.create ? 1 : 0

  description             = "KMS key for Cost Optimization Hub exports, Athena results, and Glue crawler security configuration"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms[0].json
  tags                    = var.tags
}

resource "aws_kms_alias" "this" {
  count = local.create ? 1 : 0

  name          = local.kms_alias_name
  target_key_id = aws_kms_key.this[0].key_id
}

resource "aws_s3_bucket" "export" {
  count = local.create ? 1 : 0

  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "export" {
  count = local.create ? 1 : 0

  bucket                  = aws_s3_bucket.export[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "export" {
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.export[0].id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.this[0].arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "export" {
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.export[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "export" {
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.export[0].id

  rule {
    id     = "expire-cost-optimization-exports"
    status = "Enabled"

    filter {
      prefix = var.s3_prefix
    }

    expiration {
      days = 180
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  rule {
    id     = "expire-athena-results"
    status = "Enabled"

    filter {
      prefix = "athena-results/"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.export]
}

data "aws_iam_policy_document" "export_bucket" {
  count = local.create ? 1 : 0

  statement {
    sid    = "AllowBCMDataExportsWrite"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "billingreports.amazonaws.com",
        "bcm-data-exports.amazonaws.com",
      ]
    }

    actions = [
      "s3:GetBucketPolicy",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.export[0].arn,
      "${aws_s3_bucket.export[0].arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${local.partition}:cur:us-east-1:${local.account_id}:definition/*",
        "arn:${local.partition}:bcm-data-exports:us-east-1:${local.account_id}:export/*",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "export" {
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.export[0].id
  policy = data.aws_iam_policy_document.export_bucket[0].json
}

resource "aws_costoptimizationhub_enrollment_status" "this" {
  count = local.create && var.manage_enrollment ? 1 : 0

  include_member_accounts = var.include_member_accounts
}

resource "aws_bcmdataexports_export" "recommendations" {
  count = local.create ? 1 : 0

  export {
    name        = var.export_name
    description = "Cost Optimization Hub recommendations for sprint backlog review."

    data_query {
      query_statement = "SELECT * FROM COST_OPTIMIZATION_RECOMMENDATIONS"
      table_configurations = {
        COST_OPTIMIZATION_RECOMMENDATIONS = {
          INCLUDE_ALL_RECOMMENDATIONS = upper(tostring(var.include_all_recommendations))
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.export[0].bucket
        s3_prefix = var.s3_prefix
        s3_region = local.region

        s3_output_configurations {
          overwrite   = "OVERWRITE_REPORT"
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  depends_on = [
    aws_costoptimizationhub_enrollment_status.this,
    aws_s3_bucket_policy.export,
  ]
}

resource "aws_glue_catalog_database" "this" {
  count = local.create ? 1 : 0

  name        = var.database_name
  description = "Cost Optimization Hub recommendation export catalog."
}

resource "aws_glue_security_configuration" "this" {
  count = local.create ? 1 : 0

  name = "${local.crawler_name}-security"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = aws_kms_key.this[0].arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = aws_kms_key.this[0].arn
    }
  }
}

data "aws_iam_policy_document" "glue_assume" {
  count = local.create ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:glue:${local.region}:${local.account_id}:crawler/${local.crawler_name}"]
    }
  }
}

resource "aws_iam_role" "glue_crawler" {
  count = local.create ? 1 : 0

  name               = "${local.crawler_name}-role"
  assume_role_policy = data.aws_iam_policy_document.glue_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.glue_crawler[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_crawler_s3" {
  count = local.create ? 1 : 0

  statement {
    sid       = "ReadOptimizationExport"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.export[0].arn}/${var.s3_prefix}/${var.export_name}/data/*"]
  }

  statement {
    sid       = "ListOptimizationExportPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.export[0].arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.s3_prefix}/${var.export_name}/data/*"]
    }
  }

  statement {
    sid = "UseCostOptimizationKmsKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.this[0].arn]
  }
}

resource "aws_iam_role_policy" "glue_crawler_s3" {
  count = local.create ? 1 : 0

  name   = "${local.crawler_name}-s3-read"
  role   = aws_iam_role.glue_crawler[0].id
  policy = data.aws_iam_policy_document.glue_crawler_s3[0].json
}

resource "aws_glue_crawler" "this" {
  count = local.create ? 1 : 0

  name                   = local.crawler_name
  role                   = aws_iam_role.glue_crawler[0].arn
  database_name          = aws_glue_catalog_database.this[0].name
  security_configuration = aws_glue_security_configuration.this[0].name
  table_prefix           = "coh_"

  s3_target {
    path = local.export_s3_path
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = var.tags

  depends_on = [
    aws_bcmdataexports_export.recommendations,
    aws_iam_role_policy_attachment.glue_service,
    aws_iam_role_policy.glue_crawler_s3,
  ]
}

resource "aws_athena_workgroup" "this" {
  count = local.create ? 1 : 0

  name        = var.athena_workgroup_name
  description = "Low-cost Athena workgroup for Cost Optimization Hub backlog review."
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.export[0].bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.this[0].arn
      }
    }
  }

  tags = var.tags
}
