############################################
# MANDATE-11.2 — Event Filtering Pipeline
# Reproduces exactly the working console/CLI setup:
#   CloudTrail  -> CW Logs -> Subscription Filter -> Firehose -> S3
#   EKS Audit   -> CW Logs -> Subscription Filter -> Lambda (fine filter) -> Firehose -> S3
############################################

data "aws_caller_identity" "current" {}

############################################
# S3 — audit event store
############################################

resource "aws_s3_bucket" "audit_events" {
  bucket = var.audit_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "audit_events" {
  bucket = aws_s3_bucket.audit_events.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "audit_events" {
  bucket                  = aws_s3_bucket.audit_events.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################################
# CloudTrail
############################################

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = var.cloudtrail_log_group_name
  retention_in_days = var.raw_log_retention_days
  tags              = var.tags
}

# CloudTrail -> CloudWatch Logs delivery role (proven working: ExternalId condition only)
resource "aws_iam_role" "cloudtrail_to_cwl" {
  name = "${var.project_name}-cloudtrail-to-cwl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cloudtrail_to_cwl" {
  name = "${var.project_name}-cloudtrail-to-cwl-policy"
  role = aws_iam_role.cloudtrail_to_cwl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:PutLogEvents", "logs:CreateLogStream"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "audit" {
  name                          = var.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.audit_events.id
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_to_cwl.arn
  enable_log_file_validation    = true
  include_global_service_events = true
  is_multi_region_trail         = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.cloudtrail_to_cwl]
}

############################################
# Firehose -> S3 (proven working: ExternalId condition trust policy)
############################################

resource "aws_iam_role" "firehose_to_s3" {
  name = "${var.project_name}-firehose-audit-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "firehose_delivery" {
  name              = "/aws/kinesisfirehose/${var.firehose_stream_name}"
  retention_in_days = var.raw_log_retention_days
  tags              = var.tags
}

resource "aws_iam_role_policy" "firehose_to_s3" {
  name = "${var.project_name}-firehose-audit-s3-policy"
  role = aws_iam_role.firehose_to_s3.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject",
        ]
        Resource = [
          aws_s3_bucket.audit_events.arn,
          "${aws_s3_bucket.audit_events.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.firehose_delivery.arn}:log-stream:*"
      },
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "audit_events" {
  name        = var.firehose_stream_name
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose_to_s3.arn
    bucket_arn          = aws_s3_bucket.audit_events.arn
    prefix              = "high-risk-events/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "firehose-errors/!{firehose:error-output-type}/"
    buffering_interval  = 60
    buffering_size      = 1
    compression_format  = "GZIP"

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose_delivery.name
      log_stream_name = "DestinationDelivery"
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.firehose_to_s3]
}

############################################
# CloudWatch Logs -> Firehose (CloudTrail branch)
# NOTE: proven-working trust policy has NO ArnLike SourceArn condition —
# the exact SourceArn format CloudWatch Logs sends caused AssumeRole to be
# silently denied during debugging. Only SourceAccount is kept as a safe
# minimum. If you want to re-tighten with ArnLike later, capture the real
# SourceArn from a successful AssumeRole CloudTrail event first.
############################################

resource "aws_iam_role" "cwlogs_to_firehose" {
  name = "${var.project_name}-cwlogs-to-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "cwlogs_to_firehose" {
  name = "${var.project_name}-cwlogs-to-firehose-policy"
  role = aws_iam_role.cwlogs_to_firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "firehose:PutRecord",
        "firehose:PutRecordBatch",
        "firehose:DescribeDeliveryStream",
      ]
      Resource = aws_kinesis_firehose_delivery_stream.audit_events.arn
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "cloudtrail_high_risk" {
  name            = "high-risk-cloudtrail-events"
  log_group_name  = aws_cloudwatch_log_group.cloudtrail.name
  filter_pattern  = var.cloudtrail_filter_pattern
  destination_arn = aws_kinesis_firehose_delivery_stream.audit_events.arn
  role_arn        = aws_iam_role.cwlogs_to_firehose.arn

  depends_on = [aws_iam_role_policy.cwlogs_to_firehose]
}

############################################
# EKS audit log group (log types themselves must be enabled on the
# aws_eks_cluster resource in modules/eks — see README.md in this module
# for the exact variable wiring, it cannot be managed from here).
############################################

resource "aws_cloudwatch_log_group" "eks_audit_retention" {
  count             = var.manage_eks_log_group_retention ? 1 : 0
  name              = "/aws/eks/${var.eks_cluster_name}/cluster"
  retention_in_days = var.raw_log_retention_days
  tags              = var.tags

  lifecycle {
    # EKS creates this log group automatically when control plane logging
    # is enabled; this resource only imports/manages retention, never
    # creation, to avoid fighting AWS's own lifecycle for it.
    prevent_destroy = false
  }
}

############################################
# Lambda — fine-grained K8s audit filter
############################################

data "archive_file" "k8s_audit_fine_filter" {
  type        = "zip"
  source_file = "${path.module}/lambda/k8s_audit_fine_filter.py"
  output_path = "${path.module}/lambda/k8s_audit_fine_filter.zip"
}

resource "aws_iam_role" "lambda_k8s_filter" {
  name = "${var.project_name}-k8s-audit-fine-filter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "lambda_basic_exec" {
  role       = aws_iam_role.lambda_k8s_filter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_firehose_put" {
  name = "${var.project_name}-lambda-firehose-put"
  role = aws_iam_role.lambda_k8s_filter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "firehose:PutRecordBatch"
      Resource = aws_kinesis_firehose_delivery_stream.audit_events.arn
    }]
  })
}

resource "aws_lambda_function" "k8s_audit_fine_filter" {
  function_name    = "k8s-audit-fine-filter"
  role             = aws_iam_role.lambda_k8s_filter.arn
  handler          = "k8s_audit_fine_filter.handler"
  runtime          = "python3.13"
  timeout          = 30
  filename         = data.archive_file.k8s_audit_fine_filter.output_path
  source_code_hash = data.archive_file.k8s_audit_fine_filter.output_base64sha256

  environment {
    variables = {
      FIREHOSE_STREAM_NAME        = aws_kinesis_firehose_delivery_stream.audit_events.name
      ALLOWED_ACTORS              = var.allowed_actors_csv
      PRODUCTION_NAMESPACE_PREFIX = var.production_namespace_prefix
    }
  }

  tags = var.tags
}

resource "aws_lambda_permission" "cwlogs_invoke" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.k8s_audit_fine_filter.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.eks_cluster_name}/cluster:*"
}

resource "aws_cloudwatch_log_subscription_filter" "k8s_audit_high_risk" {
  name            = "high-risk-k8s-events"
  log_group_name  = "/aws/eks/${var.eks_cluster_name}/cluster"
  filter_pattern  = var.k8s_audit_filter_pattern
  destination_arn = aws_lambda_function.k8s_audit_fine_filter.arn

  depends_on = [aws_lambda_permission.cwlogs_invoke]
}
