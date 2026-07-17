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

  account_id       = local.create ? data.aws_caller_identity.current[0].account_id : "000000000000"
  region           = local.create ? data.aws_region.current[0].name : "us-east-1"
  partition        = local.create ? data.aws_partition.current[0].partition : "aws"
  kms_alias_name   = "alias/${var.name_prefix}-cur-athena"
  crawler_name     = coalesce(var.crawler_name, "${var.name_prefix}-cur-athena")
  oidc_issuer_path = replace(var.oidc_issuer_url, "https://", "")
  grafana_subject  = "system:serviceaccount:${var.grafana_namespace}:${var.grafana_service_account_name}"

  cur_data_path = "s3://${var.cur_bucket_name}/${var.cur_s3_prefix}/${var.cur_export_name}/data/"
}

data "aws_iam_policy_document" "cur_athena_kms" {
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the policy is scoped to the key it is attached to.
  #checkov:skip=CKV_AWS_109:KMS key administrator policy is scoped by the attached key policy document and account root principal.
  #checkov:skip=CKV_AWS_111:KMS key administrator policy is scoped by the attached key policy document and account root principal.
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
}

resource "aws_kms_key" "cur_athena" {
  count = local.create ? 1 : 0

  description             = "KMS key for CUR Athena results and Glue crawler security configuration"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cur_athena_kms[0].json
  tags                    = var.tags
}

resource "aws_kms_alias" "cur_athena" {
  count = local.create ? 1 : 0

  name          = local.kms_alias_name
  target_key_id = aws_kms_key.cur_athena[0].key_id
}

resource "aws_s3_bucket" "athena_results" {
  count = local.create ? 1 : 0

  bucket = var.athena_results_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  count = local.create ? 1 : 0

  bucket                  = aws_s3_bucket.athena_results[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.athena_results[0].id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.cur_athena[0].arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "athena_results" {
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.athena_results[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  #checkov:skip=CKV_AWS_300:Lifecycle rule includes abort_incomplete_multipart_upload; Checkov does not correlate it reliably with counted resources.
  count = local.create ? 1 : 0

  bucket = aws_s3_bucket.athena_results[0].id

  rule {
    id     = "expire-athena-results"
    status = "Enabled"

    filter {
      prefix = "results/"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.athena_results]
}

resource "aws_glue_catalog_database" "cur" {
  count = local.create ? 1 : 0

  name        = var.database_name
  description = "CUR 2.0 Data Export catalog for Grafana/Athena FinOps dashboards."
}

resource "aws_glue_security_configuration" "cur" {
  count = local.create ? 1 : 0

  name = "${local.crawler_name}-security"

  encryption_configuration {
    cloudwatch_encryption {
      cloudwatch_encryption_mode = "SSE-KMS"
      kms_key_arn                = aws_kms_key.cur_athena[0].arn
    }

    s3_encryption {
      s3_encryption_mode = "SSE-KMS"
      kms_key_arn        = aws_kms_key.cur_athena[0].arn
    }

    job_bookmarks_encryption {
      job_bookmarks_encryption_mode = "CSE-KMS"
      kms_key_arn                   = aws_kms_key.cur_athena[0].arn
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

data "aws_iam_policy_document" "glue_s3_read" {
  count = local.create ? 1 : 0

  statement {
    sid       = "ReadCurExport"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.cur_bucket_name}/${var.cur_s3_prefix}/${var.cur_export_name}/data/*"]
  }

  statement {
    sid       = "ListCurExportPrefix"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.cur_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.cur_s3_prefix}/${var.cur_export_name}/data/*"]
    }
  }

  statement {
    sid = "UseCurAthenaKmsKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.cur_athena[0].arn]
  }
}

resource "aws_iam_role_policy" "glue_s3_read" {
  count = local.create ? 1 : 0

  name   = "${local.crawler_name}-s3-read"
  role   = aws_iam_role.glue_crawler[0].id
  policy = data.aws_iam_policy_document.glue_s3_read[0].json
}

resource "aws_glue_crawler" "cur" {
  count = local.create ? 1 : 0

  name                   = local.crawler_name
  role                   = aws_iam_role.glue_crawler[0].arn
  database_name          = aws_glue_catalog_database.cur[0].name
  security_configuration = aws_glue_security_configuration.cur[0].name

  s3_target {
    path = local.cur_data_path
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.glue_service,
    aws_iam_role_policy.glue_s3_read,
  ]
}

resource "aws_athena_workgroup" "grafana_cur" {
  count = local.create ? 1 : 0

  name        = var.athena_workgroup_name
  description = "Low-cost Athena workgroup for Grafana CUR dashboards."
  state       = "ENABLED"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results[0].bucket}/results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.cur_athena[0].arn
      }
    }
  }

  tags = var.tags
}

data "aws_iam_policy_document" "grafana_assume" {
  count = local.create ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_path}:sub"
      values   = [local.grafana_subject]
    }
  }
}

resource "aws_iam_role" "grafana_athena" {
  count = local.create ? 1 : 0

  name               = "${var.name_prefix}-grafana-athena"
  assume_role_policy = data.aws_iam_policy_document.grafana_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "grafana_athena" {
  count = local.create ? 1 : 0

  statement {
    sid = "AthenaQueryCur"
    actions = [
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
    ]
    resources = [
      "arn:${local.partition}:athena:${local.region}:${local.account_id}:workgroup/${var.athena_workgroup_name}",
    ]
  }

  statement {
    sid = "ReadGlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
    ]
    resources = [
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:catalog",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:database/${var.database_name}",
      "arn:${local.partition}:glue:${local.region}:${local.account_id}:table/${var.database_name}/*",
    ]
  }

  statement {
    sid       = "ReadCurExport"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.cur_bucket_name}/${var.cur_s3_prefix}/${var.cur_export_name}/data/*"]
  }

  statement {
    sid       = "ListCurExport"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.cur_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.cur_s3_prefix}/${var.cur_export_name}/data/*"]
    }
  }

  statement {
    sid = "ListAthenaResults"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.athena_results[0].arn]
  }

  statement {
    sid = "WriteAthenaResults"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.athena_results[0].arn}/*"]
  }

  statement {
    sid = "UseCurAthenaKmsKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.cur_athena[0].arn]
  }
}

resource "aws_iam_role_policy" "grafana_athena" {
  count = local.create ? 1 : 0

  name   = "${var.name_prefix}-grafana-athena"
  role   = aws_iam_role.grafana_athena[0].id
  policy = data.aws_iam_policy_document.grafana_athena[0].json
}
