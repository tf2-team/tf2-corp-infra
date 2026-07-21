locals {
  immutable_audit_discord_enabled = var.immutable_audit_discord_alert_enabled
  immutable_audit_health_enabled  = var.immutable_audit_health_check_enabled
  immutable_audit_health_check_name = (
    "${local.immutable_audit_trail_name}-health-check"
  )
  immutable_audit_health_check_lambda_arn = (
    "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.immutable_audit_health_check_name}"
  )

  immutable_audit_discord_webhook_secret_arn = (
    var.immutable_audit_discord_webhook_secret_arn != ""
    ? var.immutable_audit_discord_webhook_secret_arn
    : try(aws_secretsmanager_secret.immutable_audit_discord_webhook[0].arn, "")
  )
}

data "aws_iam_policy_document" "immutable_audit_alert_runtime_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; service statements are limited to Lambda and Secrets Manager.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
  count = local.immutable_audit_discord_enabled || local.immutable_audit_health_enabled ? 1 : 0

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

  statement {
    sid    = "AllowLambdaUseOfKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowSecretsManagerUseOfKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["secretsmanager.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "immutable_audit_alert_runtime" {
  count = local.immutable_audit_discord_enabled || local.immutable_audit_health_enabled ? 1 : 0

  description             = "KMS key for ${local.immutable_audit_trail_name} Discord alert and health check runtime secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.immutable_audit_alert_runtime_kms[0].json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-alert-runtime-kms"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-alert-runtime"
  })
}

resource "aws_kms_alias" "immutable_audit_alert_runtime" {
  count = local.immutable_audit_discord_enabled || local.immutable_audit_health_enabled ? 1 : 0

  name          = "alias/${local.immutable_audit_trail_name}-alert-runtime"
  target_key_id = aws_kms_key.immutable_audit_alert_runtime[0].key_id
}

resource "aws_secretsmanager_secret" "immutable_audit_discord_webhook" {
  count = local.immutable_audit_discord_enabled && var.immutable_audit_discord_webhook_secret_arn == "" ? 1 : 0

  name       = "${local.immutable_audit_trail_name}-discord-webhook"
  kms_key_id = aws_kms_key.immutable_audit_alert_runtime[0].arn

  description = "Discord webhook URL for Mandate 12 immutable audit alerts. Value is bootstrapped outside Terraform."

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-webhook"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

data "archive_file" "immutable_audit_discord_forwarder" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/immutable_audit_discord_forwarder.py"
  output_path = "${path.module}/lambda/build/immutable-audit-discord-forwarder.zip"
}

data "archive_file" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/immutable_audit_health_check.py"
  output_path = "${path.module}/lambda/build/immutable-audit-health-check.zip"
}

resource "aws_sqs_queue" "immutable_audit_discord_dlq" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  name                      = "${local.immutable_audit_trail_name}-discord-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-dlq"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-dlq"
  })
}

resource "aws_sqs_queue" "immutable_audit_discord_lambda_dlq" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  name                      = "${local.immutable_audit_trail_name}-discord-lambda-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-lambda-dlq"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-lambda-dlq"
  })
}

resource "aws_sqs_queue" "immutable_audit_health_lambda_dlq" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  name                      = "${local.immutable_audit_trail_name}-health-lambda-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-health-lambda-dlq"
    Mandate = "MD12"
    Purpose = "audit-control-health-lambda-dlq"
  })
}

resource "aws_sqs_queue" "immutable_audit_discord" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  name                       = "${local.immutable_audit_trail_name}-discord-alerts"
  message_retention_seconds  = 345600
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.immutable_audit_discord_dlq[0].arn
    maxReceiveCount     = 3
  })

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-alerts"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

data "aws_iam_policy_document" "immutable_audit_discord_queue" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  statement {
    sid    = "AllowEventBridgeTamperRules"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_discord[0].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for rule in aws_cloudwatch_event_rule.immutable_audit_tamper : rule.arn]
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
    resources = [aws_sqs_queue.immutable_audit_discord[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "immutable_audit_discord_dlq" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.immutable_audit_discord_dlq[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "immutable_audit_discord_lambda_dlq" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "immutable_audit_health_lambda_dlq" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.immutable_audit_health_lambda_dlq[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "immutable_audit_discord" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  queue_url = aws_sqs_queue.immutable_audit_discord[0].url
  policy    = data.aws_iam_policy_document.immutable_audit_discord_queue[0].json
}

resource "aws_sqs_queue_policy" "immutable_audit_discord_dlq" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  queue_url = aws_sqs_queue.immutable_audit_discord_dlq[0].url
  policy    = data.aws_iam_policy_document.immutable_audit_discord_dlq[0].json
}

resource "aws_sqs_queue_policy" "immutable_audit_discord_lambda_dlq" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  queue_url = aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].url
  policy    = data.aws_iam_policy_document.immutable_audit_discord_lambda_dlq[0].json
}

resource "aws_sqs_queue_policy" "immutable_audit_health_lambda_dlq" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  queue_url = aws_sqs_queue.immutable_audit_health_lambda_dlq[0].url
  policy    = data.aws_iam_policy_document.immutable_audit_health_lambda_dlq[0].json
}

resource "aws_cloudwatch_event_target" "immutable_audit_tamper_discord" {
  for_each = local.immutable_audit_discord_enabled ? aws_cloudwatch_event_rule.immutable_audit_tamper : {}

  rule      = each.value.name
  target_id = "discord-audit-alert"
  arn       = aws_sqs_queue.immutable_audit_discord[0].arn

  depends_on = [aws_sqs_queue_policy.immutable_audit_discord]
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "immutable_audit_discord_forwarder" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  name               = "${local.immutable_audit_trail_name}-discord-forwarder"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-forwarder"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

data "aws_iam_policy_document" "immutable_audit_discord_forwarder" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  statement {
    sid    = "WriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.immutable_audit_discord_forwarder[0].arn}:*"]
  }

  statement {
    sid    = "ReadDiscordWebhook"
    effect = "Allow"

    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.immutable_audit_discord_webhook_secret_arn]
  }

  statement {
    sid    = "UseRuntimeKmsKey"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
    ]
    resources = [aws_kms_key.immutable_audit_alert_runtime[0].arn]
  }

  statement {
    sid    = "ConsumeDiscordQueue"
    effect = "Allow"

    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.immutable_audit_discord[0].arn]
  }

  statement {
    sid    = "WriteLambdaDlq"
    effect = "Allow"

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].arn]
  }

}

resource "aws_iam_role_policy" "immutable_audit_discord_forwarder" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  name   = "${local.immutable_audit_trail_name}-discord-forwarder"
  role   = aws_iam_role.immutable_audit_discord_forwarder[0].id
  policy = data.aws_iam_policy_document.immutable_audit_discord_forwarder[0].json
}

resource "aws_cloudwatch_log_group" "immutable_audit_discord_forwarder" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  name              = "/aws/lambda/${local.immutable_audit_trail_name}-discord-forwarder"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name    = "/aws/lambda/${local.immutable_audit_trail_name}-discord-forwarder"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

resource "aws_lambda_function" "immutable_audit_discord_forwarder" {
  #checkov:skip=CKV_AWS_50:CloudWatch Logs, Lambda metrics, alarms, and DLQs are sufficient for this low-volume audit alert path; X-Ray is deferred to avoid extra telemetry cost and IAM surface.
  #checkov:skip=CKV_AWS_117:Discord webhook delivery requires public egress; keeping the Lambda outside VPC avoids NAT dependency for the audit alert path.
  #checkov:skip=CKV_AWS_272:Code signing is deferred because this repo does not yet manage a signing profile; source hash and Terraform review remain the deployment control for this capstone.
  count = local.immutable_audit_discord_enabled ? 1 : 0

  function_name    = "${local.immutable_audit_trail_name}-discord-forwarder"
  description      = "Forwards Mandate 12 audit tamper events from SQS to Discord."
  role             = aws_iam_role.immutable_audit_discord_forwarder[0].arn
  handler          = "immutable_audit_discord_forwarder.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.immutable_audit_discord_forwarder[0].output_path
  kms_key_arn      = aws_kms_key.immutable_audit_alert_runtime[0].arn
  source_code_hash = data.archive_file.immutable_audit_discord_forwarder[0].output_base64sha256
  timeout          = 10
  # Keep these audit Lambdas on account-level unreserved concurrency. The
  # workload account currently cannot reserve more concurrency without dropping
  # below Lambda's required unreserved concurrency floor.
  reserved_concurrent_executions = -1

  dead_letter_config {
    target_arn = aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].arn
  }

  environment {
    variables = {
      DISCORD_WEBHOOK_SECRET_ARN = local.immutable_audit_discord_webhook_secret_arn
    }
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-forwarder"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })

  depends_on = [
    aws_cloudwatch_log_group.immutable_audit_discord_forwarder,
    aws_iam_role_policy.immutable_audit_discord_forwarder,
  ]
}

resource "aws_lambda_event_source_mapping" "immutable_audit_discord_forwarder" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  event_source_arn        = aws_sqs_queue.immutable_audit_discord[0].arn
  function_name           = aws_lambda_function.immutable_audit_discord_forwarder[0].arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_iam_role" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  name               = local.immutable_audit_health_check_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = merge(var.tags, {
    Name    = local.immutable_audit_health_check_name
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })
}

data "aws_iam_policy_document" "immutable_audit_health_check" {
  #checkov:skip=CKV_AWS_356:cloudwatch:PutMetricData, cloudtrail status reads, and logs:DescribeLogGroups require Resource "*" or are not resource-scoped by AWS; restrictable checks below are scoped to audit resources.
  count = local.immutable_audit_health_enabled ? 1 : 0

  statement {
    sid    = "WriteLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.immutable_audit_health_check[0].arn}:*"]
  }

  statement {
    sid    = "PublishHealthMetric"
    effect = "Allow"

    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadCloudTrailState"
    effect = "Allow"

    actions = [
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetEventSelectors",
      "cloudtrail:GetTrailStatus",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadAuditStorageState"
    effect = "Allow"

    actions = [
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketVersioning",
    ]
    resources = [
      aws_s3_bucket.immutable_audit.arn,
      aws_s3_bucket.immutable_audit_k8s_raw.arn,
    ]
  }

  statement {
    sid    = "ListValidationReports"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.immutable_audit_k8s_raw.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        "${local.immutable_audit_validation_report_prefix}/*",
      ]
    }
  }

  statement {
    sid    = "ReadValidationReports"
    effect = "Allow"

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.immutable_audit_k8s_raw.arn}/${local.immutable_audit_validation_report_prefix}/*"]
  }

  statement {
    sid    = "ReadAuditKmsState"
    effect = "Allow"

    actions = ["kms:DescribeKey"]
    resources = compact([
      aws_kms_key.immutable_audit.arn,
      aws_kms_key.immutable_audit_sns.arn,
      aws_kms_key.immutable_audit_alert_sns.arn,
      aws_kms_key.immutable_audit_alert_runtime[0].arn,
      try(aws_kms_key.immutable_audit_k8s_firehose.arn, ""),
      try(aws_kms_key.immutable_audit_k8s_sealer_runtime[0].arn, ""),
      try(aws_kms_key.immutable_audit_k8s_sealer_signing[0].arn, ""),
      try(aws_kms_key.immutable_audit_validation_runtime[0].arn, ""),
    ])
  }

  dynamic "statement" {
    for_each = local.immutable_audit_k8s_sealer_enabled ? [1] : []

    content {
      sid    = "ReadK8sSealerCheckpointTable"
      effect = "Allow"

      actions   = ["dynamodb:GetItem"]
      resources = [aws_dynamodb_table.immutable_audit_k8s_sealer_checkpoint[0].arn]
    }
  }

  dynamic "statement" {
    for_each = local.immutable_audit_k8s_sealer_enabled ? [1] : []

    content {
      sid    = "ReadK8sSealerCheckpointKms"
      effect = "Allow"

      actions   = ["kms:Decrypt"]
      resources = [aws_kms_key.immutable_audit_k8s_sealer_runtime[0].arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["dynamodb.${var.aws_region}.amazonaws.com"]
      }
    }
  }

  statement {
    sid    = "UseRuntimeKmsKey"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
    ]
    resources = [aws_kms_key.immutable_audit_alert_runtime[0].arn]
  }

  statement {
    sid    = "ReadAlertPipelineState"
    effect = "Allow"

    actions = [
      "events:DescribeRule",
      "events:ListTargetsByRule",
    ]
    resources = concat(
      concat(
        [for rule in aws_cloudwatch_event_rule.immutable_audit_tamper : rule.arn],
        [aws_cloudwatch_event_rule.immutable_audit_health_check[0].arn]
      ),
      compact([
        try(aws_cloudwatch_event_rule.immutable_audit_k8s_sealer[0].arn, ""),
        try(aws_cloudwatch_event_rule.immutable_audit_cloudtrail_validator[0].arn, ""),
        try(aws_cloudwatch_event_rule.immutable_audit_k8s_manifest_validator[0].arn, ""),
      ])
    )
  }

  statement {
    sid    = "ReadSnsSubscriptionState"
    effect = "Allow"

    actions   = ["sns:ListSubscriptionsByTopic"]
    resources = [aws_sns_topic.immutable_audit_tamper_alerts.arn]
  }

  statement {
    sid    = "ReadCloudWatchLogGroupState"
    effect = "Allow"

    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = local.immutable_audit_discord_enabled ? [1] : []

    content {
      sid    = "ReadDiscordSecretMetadata"
      effect = "Allow"

      actions   = ["secretsmanager:DescribeSecret"]
      resources = [local.immutable_audit_discord_webhook_secret_arn]
    }
  }

  statement {
    sid    = "WriteLambdaDlq"
    effect = "Allow"

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.immutable_audit_health_lambda_dlq[0].arn]
  }

  statement {
    sid    = "ReadAuditDlqDepth"
    effect = "Allow"

    actions = ["sqs:GetQueueAttributes"]
    resources = compact([
      local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord_dlq[0].arn : "",
      local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].arn : "",
      aws_sqs_queue.immutable_audit_health_lambda_dlq[0].arn,
      try(aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn, ""),
      try(aws_sqs_queue.immutable_audit_validation_dlq[0].arn, ""),
    ])
  }

}

resource "aws_iam_role_policy" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  name   = local.immutable_audit_health_check_name
  role   = aws_iam_role.immutable_audit_health_check[0].id
  policy = data.aws_iam_policy_document.immutable_audit_health_check[0].json
}

resource "aws_cloudwatch_log_group" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  name              = "/aws/lambda/${local.immutable_audit_health_check_name}"
  retention_in_days = 30

  tags = merge(var.tags, {
    Name    = "/aws/lambda/${local.immutable_audit_health_check_name}"
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })
}

resource "aws_lambda_function" "immutable_audit_health_check" {
  #checkov:skip=CKV_AWS_50:CloudWatch Logs, Lambda metrics, alarms, and DLQs are sufficient for this scheduled control check; X-Ray is deferred to avoid extra telemetry cost and IAM surface.
  #checkov:skip=CKV_AWS_117:Health checker only calls AWS public APIs; keeping it outside VPC avoids NAT dependency for the audit control plane.
  #checkov:skip=CKV_AWS_272:Code signing is deferred because this repo does not yet manage a signing profile; source hash and Terraform review remain the deployment control for this capstone.
  count = local.immutable_audit_health_enabled ? 1 : 0

  function_name    = local.immutable_audit_health_check_name
  description      = "Checks Mandate 12 audit controls and publishes a health metric."
  role             = aws_iam_role.immutable_audit_health_check[0].arn
  handler          = "immutable_audit_health_check.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.immutable_audit_health_check[0].output_path
  kms_key_arn      = aws_kms_key.immutable_audit_alert_runtime[0].arn
  source_code_hash = data.archive_file.immutable_audit_health_check[0].output_base64sha256
  timeout          = 30
  # Keep these audit Lambdas on account-level unreserved concurrency. The
  # workload account currently cannot reserve more concurrency without dropping
  # below Lambda's required unreserved concurrency floor.
  reserved_concurrent_executions = -1

  dead_letter_config {
    target_arn = aws_sqs_queue.immutable_audit_health_lambda_dlq[0].arn
  }

  environment {
    variables = {
      AUDIT_BUCKET                = aws_s3_bucket.immutable_audit.bucket
      CLOUDWATCH_LOG_GROUP        = aws_cloudwatch_log_group.immutable_audit.name
      CLOUDWATCH_RETENTION_DAYS   = tostring(var.immutable_audit_cloudwatch_retention_days)
      DISCORD_ALERT_QUEUE_ARN     = local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord[0].arn : ""
      DISCORD_WEBHOOK_SECRET_ARN  = local.immutable_audit_discord_enabled ? local.immutable_audit_discord_webhook_secret_arn : ""
      EXPECTED_S3_DATA_EVENT_ARNS = jsonencode(sort(tolist(var.immutable_audit_s3_data_event_object_arns)))
      EXPECTED_SCHEDULED_TARGETS_BY_RULE = jsonencode(merge(
        {
          (aws_cloudwatch_event_rule.immutable_audit_health_check[0].name) = [local.immutable_audit_health_check_lambda_arn]
        },
        local.immutable_audit_k8s_sealer_enabled ? {
          (aws_cloudwatch_event_rule.immutable_audit_k8s_sealer[0].name) = [aws_lambda_function.immutable_audit_k8s_sealer[0].arn]
        } : {},
        local.immutable_audit_validation_enabled ? {
          (aws_cloudwatch_event_rule.immutable_audit_cloudtrail_validator[0].name)   = [aws_lambda_function.immutable_audit_cloudtrail_validator[0].arn]
          (aws_cloudwatch_event_rule.immutable_audit_k8s_manifest_validator[0].name) = [aws_lambda_function.immutable_audit_k8s_manifest_validator[0].arn]
        } : {}
      ))
      K8S_SEALER_CHECKPOINT_TABLE = try(aws_dynamodb_table.immutable_audit_k8s_sealer_checkpoint[0].name, "")
      K8S_SEALER_CHAIN_ID         = try(local.immutable_audit_k8s_sealer_chain_id, "")
      KMS_KEY_IDS = jsonencode(compact([
        aws_kms_key.immutable_audit.arn,
        aws_kms_key.immutable_audit_sns.arn,
        aws_kms_key.immutable_audit_alert_sns.arn,
        aws_kms_key.immutable_audit_alert_runtime[0].arn,
        try(aws_kms_key.immutable_audit_k8s_firehose.arn, ""),
        try(aws_kms_key.immutable_audit_k8s_sealer_runtime[0].arn, ""),
        try(aws_kms_key.immutable_audit_k8s_sealer_signing[0].arn, ""),
        try(aws_kms_key.immutable_audit_validation_runtime[0].arn, ""),
      ]))
      MAX_DELIVERY_AGE_MINUTES          = tostring(var.immutable_audit_health_check_max_delivery_age_minutes)
      MAX_DLQ_VISIBLE_MESSAGES          = tostring(var.immutable_audit_health_check_max_dlq_visible_messages)
      MAX_VALIDATION_REPORT_AGE_MINUTES = tostring(var.immutable_audit_health_check_max_validation_report_age_minutes)
      OBJECT_LOCK_DAYS                  = tostring(var.immutable_audit_retention_days)
      OBJECT_LOCK_MODE                  = var.immutable_audit_retention_mode
      RAW_ARCHIVE_BUCKET                = aws_s3_bucket.immutable_audit_k8s_raw.bucket
      RAW_ARCHIVE_OBJECT_LOCK_DAYS      = tostring(var.immutable_audit_k8s_raw_archive_retention_days)
      RAW_ARCHIVE_OBJECT_LOCK_MODE      = var.immutable_audit_k8s_raw_archive_retention_mode
      TAMPER_RULE_NAMES                 = jsonencode([for rule in aws_cloudwatch_event_rule.immutable_audit_tamper : rule.name])
      TAMPER_TOPIC_ARN                  = aws_sns_topic.immutable_audit_tamper_alerts.arn
      TAMPER_TOPIC_RULE_NAMES           = jsonencode([for key, rule in aws_cloudwatch_event_rule.immutable_audit_tamper : rule.name if contains(local.immutable_audit_email_tamper_rule_keys, key)])
      TRAIL_NAME                        = aws_cloudtrail.immutable_audit.name
      VALIDATION_REPORT_BUCKET          = aws_s3_bucket.immutable_audit_k8s_raw.bucket
      VALIDATION_REPORT_PREFIX          = try(local.immutable_audit_validation_report_prefix, "validation-reports")
      VALIDATION_REPORT_TYPES           = jsonencode(["cloudtrail", "k8s-manifests"])
      AUDIT_DLQ_URLS = jsonencode(compact([
        local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord_dlq[0].url : "",
        local.immutable_audit_discord_enabled ? aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].url : "",
        aws_sqs_queue.immutable_audit_health_lambda_dlq[0].url,
        try(aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].url, ""),
        try(aws_sqs_queue.immutable_audit_validation_dlq[0].url, ""),
      ]))
    }
  }

  tags = merge(var.tags, {
    Name    = local.immutable_audit_health_check_name
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })

  depends_on = [
    aws_cloudwatch_log_group.immutable_audit_health_check,
    aws_iam_role_policy.immutable_audit_health_check,
  ]
}

resource "aws_cloudwatch_event_rule" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  name                = local.immutable_audit_health_check_name
  description         = "Scheduled health check for Mandate 12 immutable audit controls."
  schedule_expression = var.immutable_audit_health_check_schedule_expression
  state               = "ENABLED"

  tags = merge(var.tags, {
    Name    = local.immutable_audit_health_check_name
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })
}

resource "aws_cloudwatch_event_target" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  rule      = aws_cloudwatch_event_rule.immutable_audit_health_check[0].name
  target_id = "audit-control-health-check"
  arn       = aws_lambda_function.immutable_audit_health_check[0].arn
}

resource "aws_lambda_permission" "immutable_audit_health_check" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  statement_id  = "AllowEventBridgeAuditHealthCheck"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.immutable_audit_health_check[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.immutable_audit_health_check[0].arn
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_discord_forwarder_errors" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-discord-forwarder-errors"
  alarm_description   = "Discord audit alert forwarder has Lambda errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.immutable_audit_discord_forwarder[0].function_name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-forwarder-errors"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_discord_forwarder_throttles" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-discord-forwarder-throttles"
  alarm_description   = "Discord audit alert forwarder is throttling."
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.immutable_audit_discord_forwarder[0].function_name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-forwarder-throttles"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_discord_dlq_visible" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-discord-dlq-visible"
  alarm_description   = "Discord audit alert DLQ contains undelivered events."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.immutable_audit_discord_dlq[0].name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-dlq-visible"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_discord_lambda_dlq_visible" {
  count = local.immutable_audit_discord_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-discord-lambda-dlq-visible"
  alarm_description   = "Discord audit alert Lambda DLQ contains undelivered async events."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-discord-lambda-dlq-visible"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-discord-alerts"
  })
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_health_lambda_dlq_visible" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-health-lambda-dlq-visible"
  alarm_description   = "Audit control health check Lambda DLQ contains undelivered async events."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.immutable_audit_health_lambda_dlq[0].name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-health-lambda-dlq-visible"
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_health_check_errors" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-health-check-errors"
  alarm_description   = "Audit control health check Lambda has errors."
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.immutable_audit_health_check[0].function_name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-health-check-errors"
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })
}

resource "aws_cloudwatch_metric_alarm" "immutable_audit_control_health" {
  count = local.immutable_audit_health_enabled ? 1 : 0

  alarm_name          = "${local.immutable_audit_trail_name}-control-health"
  alarm_description   = "Audit control health check reported drift or stopped reporting."
  namespace           = "TechX/Audit"
  metric_name         = "AuditControlHealth"
  statistic           = "Minimum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.immutable_audit_tamper_alerts.arn]

  dimensions = {
    TrailName = aws_cloudtrail.immutable_audit.name
  }

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-control-health"
    Mandate = "MD12"
    Purpose = "audit-control-health-check"
  })
}
