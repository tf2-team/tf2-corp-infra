locals {
  immutable_audit_k8s_sealer_enabled         = var.immutable_audit_k8s_sealer_enabled
  immutable_audit_k8s_sealer_name            = "${var.project_name}-k8s-audit-sealer"
  immutable_audit_k8s_sealer_chain_id        = "${module.eks.cluster_name}-k8s-audit"
  immutable_audit_k8s_sealer_raw_prefix      = "raw"
  immutable_audit_k8s_sealer_manifest_prefix = "manifests"
}

data "archive_file" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/immutable_audit_k8s_sealer.py"
  output_path = "${path.module}/lambda/build/immutable-audit-k8s-sealer.zip"
}

data "aws_iam_policy_document" "immutable_audit_k8s_sealer_runtime_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached runtime key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; runtime use is granted through scoped IAM policy on the Lambda role.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

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

resource "aws_kms_key" "immutable_audit_k8s_sealer_runtime" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  description             = "KMS key for ${local.immutable_audit_k8s_sealer_name} Lambda environment and checkpoint encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.immutable_audit_k8s_sealer_runtime_kms[0].json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_k8s_sealer_name}-runtime-kms"
    Mandate = "MD12"
    Purpose = "k8s-audit-sealer-runtime-encryption"
  })
}

resource "aws_kms_alias" "immutable_audit_k8s_sealer_runtime" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name          = "alias/${local.immutable_audit_k8s_sealer_name}-runtime"
  target_key_id = aws_kms_key.immutable_audit_k8s_sealer_runtime[0].key_id
}

data "aws_iam_policy_document" "immutable_audit_k8s_sealer_signing_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached signing key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; signing use is granted through scoped IAM policy on the Lambda role.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

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

resource "aws_kms_key" "immutable_audit_k8s_sealer_signing" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  description              = "Asymmetric signing key for ${local.immutable_audit_k8s_sealer_chain_id} immutable audit manifests"
  deletion_window_in_days  = 7
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  policy                   = data.aws_iam_policy_document.immutable_audit_k8s_sealer_signing_kms[0].json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_k8s_sealer_name}-signing-kms"
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-signing"
  })
}

resource "aws_kms_alias" "immutable_audit_k8s_sealer_signing" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name          = "alias/${local.immutable_audit_k8s_sealer_name}-signing"
  target_key_id = aws_kms_key.immutable_audit_k8s_sealer_signing[0].key_id
}

resource "aws_dynamodb_table" "immutable_audit_k8s_sealer_checkpoint" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name         = "${local.immutable_audit_k8s_sealer_name}-checkpoint"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "chain_id"

  attribute {
    name = "chain_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.immutable_audit_k8s_sealer_runtime[0].arn
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_k8s_sealer_name}-checkpoint"
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-chain-checkpoint"
  })
}

resource "aws_sqs_queue" "immutable_audit_k8s_sealer_dlq" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name                      = "${local.immutable_audit_k8s_sealer_name}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_k8s_sealer_name}-dlq"
    Mandate = "MD12"
    Purpose = "k8s-audit-sealer-dlq"
  })
}

data "aws_iam_policy_document" "immutable_audit_k8s_sealer_dlq" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  statement {
    sid    = "AllowEventBridgeSealerFailures"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.immutable_audit_k8s_sealer[0].arn]
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
    resources = [aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "immutable_audit_k8s_sealer_dlq" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  queue_url = aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].url
  policy    = data.aws_iam_policy_document.immutable_audit_k8s_sealer_dlq[0].json
}

resource "aws_iam_role" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name               = local.immutable_audit_k8s_sealer_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_sealer_name
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-sealing"
  })
}

data "aws_iam_policy_document" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  statement {
    sid    = "WriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.immutable_audit_k8s_sealer[0].arn}:*"]
  }

  statement {
    sid    = "ListRawAuditObjects"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.immutable_audit_k8s_raw.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.immutable_audit_k8s_sealer_raw_prefix}/*"]
    }
  }

  statement {
    sid    = "ReadRawAuditObjects"
    effect = "Allow"

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_k8s_sealer_raw_prefix}/*"]
  }

  statement {
    sid    = "WriteSignedManifests"
    effect = "Allow"

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_k8s_sealer_manifest_prefix}/*"]
  }

  statement {
    sid    = "ReadWriteCheckpoint"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
    ]
    resources = [aws_dynamodb_table.immutable_audit_k8s_sealer_checkpoint[0].arn]
  }

  statement {
    sid    = "SignAuditManifest"
    effect = "Allow"

    actions = [
      "kms:GetPublicKey",
      "kms:Sign",
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
    resources = [aws_kms_key.immutable_audit_k8s_sealer_runtime[0].arn]
  }

  statement {
    sid    = "WriteLambdaDlq"
    effect = "Allow"

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn]
  }
}

resource "aws_iam_role_policy" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name   = local.immutable_audit_k8s_sealer_name
  role   = aws_iam_role.immutable_audit_k8s_sealer[0].id
  policy = data.aws_iam_policy_document.immutable_audit_k8s_sealer[0].json
}

resource "aws_cloudwatch_log_group" "immutable_audit_k8s_sealer" {
  #checkov:skip=CKV_AWS_158:This log group stores non-secret sealer operational logs; immutable evidence is retained in S3 Object Lock signed manifests.
  #checkov:skip=CKV_AWS_338:Thirty-day operational log retention matches existing Mandate 12 Lambdas; immutable evidence retention is enforced in the archive bucket.
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name              = "/aws/lambda/${local.immutable_audit_k8s_sealer_name}"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name    = "/aws/lambda/${local.immutable_audit_k8s_sealer_name}"
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-sealing"
  })
}

resource "aws_lambda_function" "immutable_audit_k8s_sealer" {
  #checkov:skip=CKV_AWS_50:CloudWatch Logs, Lambda metrics, alarm, EventBridge DLQ, and Lambda DLQ are sufficient for this low-volume scheduled sealer; X-Ray is deferred to keep the audit control plane minimal.
  #checkov:skip=CKV_AWS_117:The sealer only calls AWS APIs; keeping it outside VPC avoids NAT dependency for audit integrity sealing.
  #checkov:skip=CKV_AWS_272:Code signing is deferred because this repo does not yet manage a signing profile; source hash and Terraform review remain the deployment control for this capstone.
  #checkov:skip=CKV_AWS_173:The function stores only non-secret resource identifiers in environment variables; signed manifests are protected by S3 Object Lock and KMS signing.
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  function_name                  = local.immutable_audit_k8s_sealer_name
  description                    = "Seals immutable raw EKS audit archive windows into KMS-signed hash-chain manifests."
  role                           = aws_iam_role.immutable_audit_k8s_sealer[0].arn
  handler                        = "immutable_audit_k8s_sealer.handler"
  runtime                        = "python3.12"
  filename                       = data.archive_file.immutable_audit_k8s_sealer[0].output_path
  kms_key_arn                    = aws_kms_key.immutable_audit_k8s_sealer_runtime[0].arn
  source_code_hash               = data.archive_file.immutable_audit_k8s_sealer[0].output_base64sha256
  timeout                        = var.immutable_audit_k8s_sealer_lambda_timeout_seconds
  memory_size                    = var.immutable_audit_k8s_sealer_lambda_memory_mb
  reserved_concurrent_executions = -1

  dead_letter_config {
    target_arn = aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn
  }

  environment {
    variables = {
      ARCHIVE_BUCKET        = aws_s3_bucket.immutable_audit_k8s_raw.bucket
      CHAIN_ID              = local.immutable_audit_k8s_sealer_chain_id
      CHECKPOINT_TABLE_NAME = aws_dynamodb_table.immutable_audit_k8s_sealer_checkpoint[0].name
      CLUSTER_NAME          = module.eks.cluster_name
      MANIFEST_PREFIX       = local.immutable_audit_k8s_sealer_manifest_prefix
      RAW_PREFIX            = local.immutable_audit_k8s_sealer_raw_prefix
      SEALING_DELAY_MINUTES = tostring(var.immutable_audit_k8s_sealer_delay_minutes)
      SIGNING_KEY_ID        = aws_kms_key.immutable_audit_k8s_sealer_signing[0].arn
      WINDOW_MINUTES        = tostring(var.immutable_audit_k8s_sealer_window_minutes)
    }
  }

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_sealer_name
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-sealing"
  })

  depends_on = [
    aws_cloudwatch_log_group.immutable_audit_k8s_sealer,
    aws_iam_role_policy.immutable_audit_k8s_sealer,
    aws_s3_bucket_object_lock_configuration.immutable_audit_k8s_raw,
  ]
}

resource "aws_cloudwatch_event_rule" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  name                = local.immutable_audit_k8s_sealer_name
  description         = "Scheduled sealer for Mandate 12 immutable raw EKS audit manifests."
  schedule_expression = var.immutable_audit_k8s_sealer_schedule_expression
  state               = "ENABLED"

  tags = merge(var.tags, {
    Name    = local.immutable_audit_k8s_sealer_name
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-sealing"
  })
}

resource "aws_cloudwatch_event_target" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.immutable_audit_k8s_sealer[0].name
  target_id = "k8s-audit-sealer"
  arn       = aws_lambda_function.immutable_audit_k8s_sealer[0].arn

  dead_letter_config {
    arn = aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }

  depends_on = [aws_sqs_queue_policy.immutable_audit_k8s_sealer_dlq]
}

resource "aws_lambda_permission" "immutable_audit_k8s_sealer" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeK8sAuditSealer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.immutable_audit_k8s_sealer[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.immutable_audit_k8s_sealer[0].arn
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_k8s_sealer_errors" {
  count = local.immutable_audit_k8s_sealer_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_k8s_sealer_name}-errors"
  alarm_description   = "K8s audit sealer Lambda has errors; signed audit manifest chain may stop advancing."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]
  ok_actions          = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.immutable_audit_k8s_sealer[0].function_name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_k8s_sealer_name}-errors"
    Mandate = "MD12"
    Purpose = "k8s-audit-manifest-sealing"
  })
}
