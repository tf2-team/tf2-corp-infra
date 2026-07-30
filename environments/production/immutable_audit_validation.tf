locals {
  immutable_audit_validation_enabled       = var.immutable_audit_validation_enabled
  immutable_audit_validation_report_prefix = "validation-reports"
  immutable_audit_k8s_manifest_validator_name = (
    "${var.project_name}-k8s-manifest-validator"
  )
}

data "archive_file" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/immutable_audit_k8s_manifest_validator.py"
  output_path = "${path.module}/lambda/build/immutable-audit-k8s-manifest-validator.zip"
}

data "aws_iam_policy_document" "immutable_audit_validation_runtime_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached runtime key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; runtime use is granted through scoped IAM policy on the Lambda roles.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  statement {
    sid    = "EnableRootPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "immutable_audit_validation_runtime" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  description             = "KMS key for Mandate 12 validation Lambda environments"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.immutable_audit_validation_runtime_kms[0].json

  tags = merge(var.tags, {
    Name    = "${var.project_name}-audit-validation-runtime-kms"
    Mandate = "MD12"
    Purpose = "audit-validation-runtime-encryption"
  })
}

resource "aws_kms_alias" "immutable_audit_validation_runtime" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name          = "alias/${var.project_name}-audit-validation-runtime"
  target_key_id = aws_kms_key.immutable_audit_validation_runtime[0].key_id
}

resource "aws_sqs_queue" "immutable_audit_validation_dlq" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name                      = "${var.project_name}-audit-validation-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, {
    Name    = "${var.project_name}-audit-validation-dlq"
    Mandate = "MD12"
    Purpose = "audit-validation-dlq"
  })
}

data "aws_iam_policy_document" "immutable_audit_validation_dlq" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.immutable_audit_validation_dlq[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "immutable_audit_validation_dlq" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  queue_url = aws_sqs_queue.immutable_audit_validation_dlq[0].url
  policy    = data.aws_iam_policy_document.immutable_audit_validation_dlq[0].json
}

resource "aws_iam_role" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name               = local.immutable_audit_k8s_manifest_validator_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_manifest_validator_name
    Mandate = "MD12"
    Purpose = "k8s-manifest-validation"
  })
}

data "aws_iam_policy_document" "immutable_audit_k8s_manifest_validator" {
  #checkov:skip=CKV_AWS_356:cloudwatch:PutMetricData requires Resource "*"; S3/KMS/DLQ permissions are resource-scoped.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  statement {
    sid    = "WriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.immutable_audit_k8s_manifest_validator[0].arn}:*"]
  }

  statement {
    sid    = "PublishValidationMetric"
    effect = "Allow"

    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid    = "ListAuditArchive"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.immutable_audit_k8s_raw.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${local.immutable_audit_k8s_sealer_manifest_prefix}/*",
      ]
    }
  }

  statement {
    sid    = "ReadManifestsAndRawObjects"
    effect = "Allow"

    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_k8s_sealer_manifest_prefix}/*",
      "${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_k8s_sealer_raw_prefix}/*",
    ]
  }

  statement {
    sid    = "WriteValidationReports"
    effect = "Allow"

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_validation_report_prefix}/k8s-manifests/*"]
  }

  statement {
    sid    = "VerifyManifestSignatures"
    effect = "Allow"

    actions = [
      "kms:GetPublicKey",
      "kms:Verify",
    ]
    resources = [aws_kms_key.immutable_audit_k8s_sealer_signing[0].arn]
  }

  statement {
    sid    = "UseRuntimeKmsKey"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = [aws_kms_key.immutable_audit_validation_runtime[0].arn]
  }

  statement {
    sid    = "WriteLambdaDlq"
    effect = "Allow"

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_validation_dlq[0].arn]
  }
}

resource "aws_iam_role_policy" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name   = local.immutable_audit_k8s_manifest_validator_name
  role   = aws_iam_role.immutable_audit_k8s_manifest_validator[0].id
  policy = data.aws_iam_policy_document.immutable_audit_k8s_manifest_validator[0].json
}

resource "aws_cloudwatch_log_group" "immutable_audit_k8s_manifest_validator" {
  #checkov:skip=CKV_AWS_158:This log group stores non-secret validator operational logs; immutable validation reports are retained in S3 Object Lock.
  #checkov:skip=CKV_AWS_338:Thirty-day operational log retention matches existing Mandate 12 Lambdas; immutable validation reports are retained in S3 Object Lock.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name              = "/aws/lambda/${local.immutable_audit_k8s_manifest_validator_name}"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name    = "/aws/lambda/${local.immutable_audit_k8s_manifest_validator_name}"
    Mandate = "MD12"
    Purpose = "k8s-manifest-validation"
  })
}

resource "aws_lambda_function" "immutable_audit_k8s_manifest_validator" {
  #checkov:skip=CKV_AWS_50:CloudWatch Logs, Lambda metrics, alarms, and EventBridge DLQ are sufficient for this scheduled validation path; X-Ray is deferred to keep the audit control plane minimal.
  #checkov:skip=CKV_AWS_117:The validator only calls AWS APIs; keeping it outside VPC avoids NAT dependency for audit validation.
  #checkov:skip=CKV_AWS_272:Code signing is deferred because this repo does not yet manage a signing profile; source hash and Terraform review remain the deployment control for this capstone.
  #checkov:skip=CKV_AWS_173:The function stores only non-secret resource identifiers in environment variables; validation reports are protected by S3 Object Lock and KMS signing.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  function_name                  = local.immutable_audit_k8s_manifest_validator_name
  description                    = "Validates KMS-signed raw EKS audit archive manifest chains for Mandate 12."
  role                           = aws_iam_role.immutable_audit_k8s_manifest_validator[0].arn
  handler                        = "immutable_audit_k8s_manifest_validator.handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.immutable_audit_k8s_manifest_validator[0].output_path
  kms_key_arn                    = aws_kms_key.immutable_audit_validation_runtime[0].arn
  source_code_hash               = data.archive_file.immutable_audit_k8s_manifest_validator[0].output_base64sha256
  timeout                        = var.immutable_audit_validation_lambda_timeout_seconds
  memory_size                    = var.immutable_audit_validation_lambda_memory_mb
  reserved_concurrent_executions = -1

  dead_letter_config {
    target_arn = aws_sqs_queue.immutable_audit_validation_dlq[0].arn
  }

  environment {
    variables = {
      ARCHIVE_BUCKET            = aws_s3_bucket.immutable_audit_k8s_raw.bucket
      CHAIN_ID                  = local.immutable_audit_k8s_sealer_chain_id
      MANIFEST_PREFIX           = local.immutable_audit_k8s_sealer_manifest_prefix
      REPORT_PREFIX             = local.immutable_audit_validation_report_prefix
      VALIDATION_DELAY_MINUTES  = tostring(var.immutable_audit_validation_delay_minutes)
      VALIDATION_LOOKBACK_HOURS = tostring(var.immutable_audit_k8s_manifest_validation_lookback_hours)
    }
  }

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_manifest_validator_name
    Mandate = "MD12"
    Purpose = "k8s-manifest-validation"
  })

  depends_on = [
    aws_cloudwatch_log_group.immutable_audit_k8s_manifest_validator,
    aws_iam_role_policy.immutable_audit_k8s_manifest_validator,
    aws_s3_bucket_object_lock_configuration.immutable_audit_k8s_raw,
  ]
}

resource "aws_scheduler_schedule" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name                         = local.immutable_audit_k8s_manifest_validator_name
  group_name                   = aws_scheduler_schedule_group.immutable_audit[0].name
  description                  = "Scheduled K8s manifest validation report for Mandate 12."
  schedule_expression          = var.immutable_audit_validation_schedule_expression
  schedule_expression_timezone = "Etc/UTC"
  state                        = "ENABLED"
  kms_key_arn                  = aws_kms_key.immutable_audit_validation_runtime[0].arn

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.immutable_audit_k8s_manifest_validator[0].arn
    role_arn = aws_iam_role.immutable_audit_scheduler[0].arn
    input = jsonencode({
      source = "eventbridge.scheduler"
      name   = local.immutable_audit_k8s_manifest_validator_name
    })

    dead_letter_config {
      arn = aws_sqs_queue.immutable_audit_validation_dlq[0].arn
    }

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 2
    }
  }

  depends_on = [
    aws_iam_role_policy.immutable_audit_scheduler,
    aws_sqs_queue_policy.immutable_audit_validation_dlq,
  ]
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_k8s_manifest_validation" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_k8s_manifest_validator_name}-fail"
  alarm_description   = "K8s manifest validation report failed or is missing."
  namespace           = "TechX/Audit"
  metric_name         = "ImmutableAuditK8sManifestValidationPass"
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]
  ok_actions          = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    ChainId = local.immutable_audit_k8s_sealer_chain_id
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_k8s_manifest_validator_name}-fail"
    Mandate = "MD12"
    Purpose = "k8s-manifest-validation"
  })
}
