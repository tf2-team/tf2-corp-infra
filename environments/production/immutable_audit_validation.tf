locals {
  immutable_audit_validation_enabled       = var.immutable_audit_validation_enabled
  immutable_audit_validation_report_prefix = "validation-reports"
  immutable_audit_cloudtrail_validator_name = (
    "${var.project_name}-cloudtrail-validator"
  )
  immutable_audit_k8s_manifest_validator_name = (
    "${var.project_name}-k8s-manifest-validator"
  )
}

data "archive_file" "immutable_audit_cloudtrail_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/immutable_audit_cloudtrail_validator.py"
  output_path = "${path.module}/lambda/build/immutable-audit-cloudtrail-validator.zip"
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
    sid    = "AllowEventBridgeValidationFailures"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_validation_dlq[0].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        aws_cloudwatch_event_rule.immutable_audit_cloudtrail_validator[0].arn,
        aws_cloudwatch_event_rule.immutable_audit_k8s_manifest_validator[0].arn,
      ]
    }
  }

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

resource "aws_iam_role" "immutable_audit_cloudtrail_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name               = local.immutable_audit_cloudtrail_validator_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(var.tags, {
    Name    = local.immutable_audit_cloudtrail_validator_name
    Mandate = "MD12"
    Purpose = "cloudtrail-validation"
  })
}

data "aws_iam_policy_document" "immutable_audit_cloudtrail_validator" {
  #checkov:skip=CKV_AWS_356:cloudwatch:PutMetricData and CloudTrail read APIs require Resource "*" or are not resource-scoped by AWS; S3/KMS/DLQ permissions are resource-scoped.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  statement {
    sid    = "WriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.immutable_audit_cloudtrail_validator[0].arn}:*"]
  }

  statement {
    sid    = "PublishValidationMetric"
    effect = "Allow"

    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadCloudTrailState"
    effect = "Allow"

    actions = [
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ListCloudTrailEvidence"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.immutable_audit.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail/*",
        "AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail-Digest/*",
      ]
    }
  }

  statement {
    sid    = "WriteValidationReports"
    effect = "Allow"

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_validation_report_prefix}/cloudtrail/*"]
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

resource "aws_iam_role_policy" "immutable_audit_cloudtrail_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name   = local.immutable_audit_cloudtrail_validator_name
  role   = aws_iam_role.immutable_audit_cloudtrail_validator[0].id
  policy = data.aws_iam_policy_document.immutable_audit_cloudtrail_validator[0].json
}

resource "aws_cloudwatch_log_group" "immutable_audit_cloudtrail_validator" {
  #checkov:skip=CKV_AWS_158:This log group stores non-secret validator operational logs; immutable validation reports are retained in S3 Object Lock.
  #checkov:skip=CKV_AWS_338:Thirty-day operational log retention matches existing Mandate 12 Lambdas; immutable validation reports are retained in S3 Object Lock.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name              = "/aws/lambda/${local.immutable_audit_cloudtrail_validator_name}"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name    = "/aws/lambda/${local.immutable_audit_cloudtrail_validator_name}"
    Mandate = "MD12"
    Purpose = "cloudtrail-validation"
  })
}

resource "aws_lambda_function" "immutable_audit_cloudtrail_validator" {
  #checkov:skip=CKV_AWS_50:CloudWatch Logs, Lambda metrics, alarms, and EventBridge DLQ are sufficient for this scheduled validation path; X-Ray is deferred to keep the audit control plane minimal.
  #checkov:skip=CKV_AWS_117:The validator only calls AWS APIs; keeping it outside VPC avoids NAT dependency for audit validation.
  #checkov:skip=CKV_AWS_272:Code signing is deferred because this repo does not yet manage a signing profile; source hash and Terraform review remain the deployment control for this capstone.
  #checkov:skip=CKV_AWS_173:The function stores only non-secret resource identifiers in environment variables; validation reports are protected by S3 Object Lock.
  count = local.immutable_audit_validation_enabled ? 1 : 0

  function_name                  = local.immutable_audit_cloudtrail_validator_name
  description                    = "Writes scheduled CloudTrail validation health reports for Mandate 12."
  role                           = aws_iam_role.immutable_audit_cloudtrail_validator[0].arn
  handler                        = "immutable_audit_cloudtrail_validator.handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.immutable_audit_cloudtrail_validator[0].output_path
  kms_key_arn                    = aws_kms_key.immutable_audit_validation_runtime[0].arn
  source_code_hash               = data.archive_file.immutable_audit_cloudtrail_validator[0].output_base64sha256
  timeout                        = var.immutable_audit_validation_lambda_timeout_seconds
  memory_size                    = var.immutable_audit_validation_lambda_memory_mb
  reserved_concurrent_executions = -1

  dead_letter_config {
    target_arn = aws_sqs_queue.immutable_audit_validation_dlq[0].arn
  }

  environment {
    variables = {
      ACCOUNT_ID               = data.aws_caller_identity.current.account_id
      AWS_REGION_NAME          = var.aws_region
      MAX_DELIVERY_AGE_MINUTES = tostring(var.immutable_audit_health_check_max_delivery_age_minutes)
      REPORT_BUCKET            = aws_s3_bucket.immutable_audit_k8s_raw.bucket
      REPORT_PREFIX            = local.immutable_audit_validation_report_prefix
      TRAIL_BUCKET             = aws_s3_bucket.immutable_audit.bucket
      TRAIL_NAME               = aws_cloudtrail.immutable_audit.name
      VALIDATION_DELAY_MINUTES = tostring(var.immutable_audit_validation_delay_minutes)
      VALIDATION_LOOKBACK_HOURS = tostring(
        var.immutable_audit_cloudtrail_validation_lookback_hours
      )
    }
  }

  tags = merge(var.tags, {
    Name    = local.immutable_audit_cloudtrail_validator_name
    Mandate = "MD12"
    Purpose = "cloudtrail-validation"
  })

  depends_on = [
    aws_cloudwatch_log_group.immutable_audit_cloudtrail_validator,
    aws_iam_role_policy.immutable_audit_cloudtrail_validator,
    aws_s3_bucket_object_lock_configuration.immutable_audit_k8s_raw,
  ]
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

resource "aws_cloudwatch_event_rule" "immutable_audit_cloudtrail_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name                = local.immutable_audit_cloudtrail_validator_name
  description         = "Scheduled CloudTrail validation report for Mandate 12."
  schedule_expression = var.immutable_audit_validation_schedule_expression
  state               = "ENABLED"

  tags = merge(var.tags, {
    Name    = local.immutable_audit_cloudtrail_validator_name
    Mandate = "MD12"
    Purpose = "cloudtrail-validation"
  })
}

resource "aws_cloudwatch_event_rule" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  name                = local.immutable_audit_k8s_manifest_validator_name
  description         = "Scheduled K8s manifest validation report for Mandate 12."
  schedule_expression = var.immutable_audit_validation_schedule_expression
  state               = "ENABLED"

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_manifest_validator_name
    Mandate = "MD12"
    Purpose = "k8s-manifest-validation"
  })
}

resource "aws_cloudwatch_event_target" "immutable_audit_cloudtrail_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.immutable_audit_cloudtrail_validator[0].name
  target_id = "cloudtrail-validator"
  arn       = aws_lambda_function.immutable_audit_cloudtrail_validator[0].arn

  dead_letter_config {
    arn = aws_sqs_queue.immutable_audit_validation_dlq[0].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }

  depends_on = [aws_sqs_queue_policy.immutable_audit_validation_dlq]
}

resource "aws_cloudwatch_event_target" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.immutable_audit_k8s_manifest_validator[0].name
  target_id = "k8s-manifest-validator"
  arn       = aws_lambda_function.immutable_audit_k8s_manifest_validator[0].arn

  dead_letter_config {
    arn = aws_sqs_queue.immutable_audit_validation_dlq[0].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }

  depends_on = [aws_sqs_queue_policy.immutable_audit_validation_dlq]
}

resource "aws_lambda_permission" "immutable_audit_cloudtrail_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeCloudTrailValidator"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.immutable_audit_cloudtrail_validator[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.immutable_audit_cloudtrail_validator[0].arn
}

resource "aws_lambda_permission" "immutable_audit_k8s_manifest_validator" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeK8sManifestValidator"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.immutable_audit_k8s_manifest_validator[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.immutable_audit_k8s_manifest_validator[0].arn
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_cloudtrail_validation" {
  count = local.immutable_audit_validation_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_cloudtrail_validator_name}-fail"
  alarm_description   = "CloudTrail validation report failed or is missing."
  namespace           = "TechX/Audit"
  metric_name         = "ImmutableAuditCloudTrailValidationPass"
  statistic           = "Minimum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]
  ok_actions          = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    TrailName = aws_cloudtrail.immutable_audit.name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_cloudtrail_validator_name}-fail"
    Mandate = "MD12"
    Purpose = "cloudtrail-validation"
  })
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
