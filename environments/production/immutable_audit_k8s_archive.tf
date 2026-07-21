locals {
  immutable_audit_k8s_raw_archive_bucket_name = (
    var.immutable_audit_k8s_raw_archive_bucket_name != ""
    ? var.immutable_audit_k8s_raw_archive_bucket_name
    : "${var.project_name}-k8s-audit-raw-${data.aws_caller_identity.current.account_id}"
  )
  immutable_audit_k8s_raw_archive_firehose_name = "${var.project_name}-k8s-audit-raw-archive"
  immutable_audit_k8s_audit_log_group_name      = "/aws/eks/${module.eks.cluster_name}/cluster"
}

resource "aws_s3_bucket" "immutable_audit_k8s_raw" {
  #checkov:skip=CKV_AWS_18:This bucket stores immutable raw EKS audit evidence; access is audited by CloudTrail and delivery health is covered by Firehose logs/alarms.
  #checkov:skip=CKV_AWS_144:Cross-region replication is deferred for capstone budget; Object Lock and local validation are the current control.
  #checkov:skip=CKV_AWS_145:SSE-S3 is sufficient for raw audit archive MVP and avoids Firehose/KMS delivery coupling; Object Lock is the integrity/retention control.
  bucket              = local.immutable_audit_k8s_raw_archive_bucket_name
  object_lock_enabled = true
  force_destroy       = false

  tags = merge(var.tags, {
    Name      = local.immutable_audit_k8s_raw_archive_bucket_name
    Mandate   = "MD4-MD12"
    Purpose   = "immutable-k8s-audit-raw-archive"
    Retention = "${var.immutable_audit_k8s_raw_archive_retention_days}d"
  })
}

resource "aws_s3_bucket_public_access_block" "immutable_audit_k8s_raw" {
  bucket                  = aws_s3_bucket.immutable_audit_k8s_raw.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "immutable_audit_k8s_raw" {
  bucket = aws_s3_bucket.immutable_audit_k8s_raw.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "immutable_audit_k8s_raw" {
  bucket = aws_s3_bucket.immutable_audit_k8s_raw.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "immutable_audit_k8s_raw" {
  bucket = aws_s3_bucket.immutable_audit_k8s_raw.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "immutable_audit_k8s_raw" {
  bucket = aws_s3_bucket.immutable_audit_k8s_raw.id

  rule {
    default_retention {
      mode = var.immutable_audit_k8s_raw_archive_retention_mode
      days = var.immutable_audit_k8s_raw_archive_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.immutable_audit_k8s_raw]
}

resource "aws_s3_bucket_lifecycle_configuration" "immutable_audit_k8s_raw" {
  bucket = aws_s3_bucket.immutable_audit_k8s_raw.id

  rule {
    id     = "retain-immutable-k8s-audit-raw-logs"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    noncurrent_version_expiration {
      noncurrent_days = max(var.immutable_audit_k8s_raw_archive_retention_days + 1, 31)
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [
    aws_s3_bucket_object_lock_configuration.immutable_audit_k8s_raw,
    aws_s3_bucket_versioning.immutable_audit_k8s_raw,
  ]
}

data "aws_iam_policy_document" "immutable_audit_k8s_raw_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.immutable_audit_k8s_raw.arn,
      "${aws_s3_bucket.immutable_audit_k8s_raw.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyRawAuditLogDelete"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/raw/*"]
  }

  statement {
    sid    = "DenyObjectLockBypass"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:BypassGovernanceRetention",
      "s3:PutObjectLegalHold",
      "s3:PutObjectRetention",
    ]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/raw/*"]
  }
}

resource "aws_s3_bucket_policy" "immutable_audit_k8s_raw" {
  bucket = aws_s3_bucket.immutable_audit_k8s_raw.id
  policy = data.aws_iam_policy_document.immutable_audit_k8s_raw_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.immutable_audit_k8s_raw]
}

resource "aws_cloudwatch_log_group" "immutable_audit_k8s_raw_firehose" {
  name              = "/aws/kinesisfirehose/${local.immutable_audit_k8s_raw_archive_firehose_name}"
  retention_in_days = var.immutable_audit_k8s_raw_archive_firehose_log_retention_days

  tags = merge(var.tags, {
    Name    = "/aws/kinesisfirehose/${local.immutable_audit_k8s_raw_archive_firehose_name}"
    Mandate = "MD12"
    Purpose = "k8s-audit-raw-archive-delivery"
  })
}

resource "aws_cloudwatch_log_stream" "immutable_audit_k8s_raw_firehose_s3" {
  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.immutable_audit_k8s_raw_firehose.name
}

data "aws_iam_policy_document" "immutable_audit_k8s_firehose_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:firehose:${var.aws_region}:${data.aws_caller_identity.current.account_id}:deliverystream/${local.immutable_audit_k8s_raw_archive_firehose_name}"]
    }
  }
}

resource "aws_iam_role" "immutable_audit_k8s_firehose" {
  name               = "${var.project_name}-k8s-audit-raw-firehose"
  assume_role_policy = data.aws_iam_policy_document.immutable_audit_k8s_firehose_assume.json

  tags = merge(var.tags, {
    Name    = "${var.project_name}-k8s-audit-raw-firehose"
    Mandate = "MD12"
    Purpose = "k8s-audit-raw-archive-delivery"
  })
}

data "aws_iam_policy_document" "immutable_audit_k8s_firehose" {
  statement {
    sid    = "WriteRawAuditObjects"
    effect = "Allow"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      aws_s3_bucket.immutable_audit_k8s_raw.arn,
      "${aws_s3_bucket.immutable_audit_k8s_raw.arn}/*",
    ]
  }

  statement {
    sid    = "WriteFirehoseDeliveryLogs"
    effect = "Allow"

    actions = [
      "logs:PutLogEvents",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${aws_cloudwatch_log_group.immutable_audit_k8s_raw_firehose.name}:log-stream:${aws_cloudwatch_log_stream.immutable_audit_k8s_raw_firehose_s3.name}"]
  }
}

resource "aws_iam_role_policy" "immutable_audit_k8s_firehose" {
  name   = "${var.project_name}-k8s-audit-raw-firehose"
  role   = aws_iam_role.immutable_audit_k8s_firehose.id
  policy = data.aws_iam_policy_document.immutable_audit_k8s_firehose.json
}

resource "aws_kinesis_firehose_delivery_stream" "immutable_audit_k8s_raw" {
  name        = local.immutable_audit_k8s_raw_archive_firehose_name
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.immutable_audit_k8s_firehose.arn
    bucket_arn          = aws_s3_bucket.immutable_audit_k8s_raw.arn
    prefix              = "raw/cluster=${module.eks.cluster_name}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    error_output_prefix = "errors/cluster=${module.eks.cluster_name}/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/"
    buffering_size      = var.immutable_audit_k8s_raw_archive_buffering_size_mb
    buffering_interval  = var.immutable_audit_k8s_raw_archive_buffering_interval_seconds
    compression_format  = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.immutable_audit_k8s_raw_firehose.name
      log_stream_name = aws_cloudwatch_log_stream.immutable_audit_k8s_raw_firehose_s3.name
    }
  }

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_raw_archive_firehose_name
    Mandate = "MD12"
    Purpose = "k8s-audit-raw-archive-delivery"
  })

  depends_on = [
    aws_iam_role_policy.immutable_audit_k8s_firehose,
    aws_s3_bucket_object_lock_configuration.immutable_audit_k8s_raw,
    aws_s3_bucket_policy.immutable_audit_k8s_raw,
  ]
}

data "aws_iam_policy_document" "immutable_audit_k8s_logs_to_firehose_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.immutable_audit_k8s_audit_log_group_name}:*"]
    }
  }
}

resource "aws_iam_role" "immutable_audit_k8s_logs_to_firehose" {
  name               = "${var.project_name}-k8s-audit-logs-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.immutable_audit_k8s_logs_to_firehose_assume.json

  tags = merge(var.tags, {
    Name    = "${var.project_name}-k8s-audit-logs-to-firehose"
    Mandate = "MD12"
    Purpose = "k8s-audit-raw-archive-delivery"
  })
}

data "aws_iam_policy_document" "immutable_audit_k8s_logs_to_firehose" {
  statement {
    sid    = "PutAuditEventsToFirehose"
    effect = "Allow"

    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.immutable_audit_k8s_raw.arn]
  }
}

resource "aws_iam_role_policy" "immutable_audit_k8s_logs_to_firehose" {
  name   = "${var.project_name}-k8s-audit-logs-to-firehose"
  role   = aws_iam_role.immutable_audit_k8s_logs_to_firehose.id
  policy = data.aws_iam_policy_document.immutable_audit_k8s_logs_to_firehose.json
}

resource "aws_cloudwatch_log_subscription_filter" "immutable_audit_k8s_raw_archive" {
  name            = var.immutable_audit_k8s_raw_archive_subscription_filter_name
  log_group_name  = local.immutable_audit_k8s_audit_log_group_name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.immutable_audit_k8s_raw.arn
  role_arn        = aws_iam_role.immutable_audit_k8s_logs_to_firehose.arn

  depends_on = [
    aws_iam_role_policy.immutable_audit_k8s_logs_to_firehose,
    aws_kinesis_firehose_delivery_stream.immutable_audit_k8s_raw,
  ]
}
