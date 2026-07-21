data "aws_caller_identity" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_region" "current" {
  count = var.enabled ? 1 : 0
}

data "archive_file" "parser_placeholder" {
  count = var.enabled ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda/audit_alert_parser_placeholder"
  output_path = "${path.root}/lambda/build/audit-alert-parser-placeholder.zip"
}

data "archive_file" "router_placeholder" {
  count = var.enabled && var.enable_discord_router ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda/audit_alert_router_placeholder"
  output_path = "${path.root}/lambda/build/audit-alert-router-placeholder.zip"
}

locals {
  create         = var.enabled
  router_enabled = local.create && var.enable_discord_router

  account_id      = local.create ? data.aws_caller_identity.current[0].account_id : "000000000000"
  partition       = local.create ? data.aws_partition.current[0].partition : "aws"
  region          = local.create ? data.aws_region.current[0].name : "us-east-1"
  audit_log_group = var.audit_log_group_name != "" ? var.audit_log_group_name : "/aws/eks/${var.cluster_name}/cluster"

  lambda_role_name           = var.lambda_role_name != "" ? var.lambda_role_name : "${var.name_prefix}-audit-alert-parser-role"
  lambda_policy_name         = var.lambda_policy_name != "" ? var.lambda_policy_name : "${local.lambda_role_name}-policy"
  lambda_log_group_name      = "/aws/lambda/${var.lambda_function_name}"
  router_lambda_role_name    = var.router_lambda_role_name != "" ? var.router_lambda_role_name : "${var.name_prefix}-audit-alert-router-role"
  router_lambda_policy_name  = var.router_lambda_policy_name != "" ? var.router_lambda_policy_name : "${local.router_lambda_role_name}-policy"
  router_lambda_log_group    = "/aws/lambda/${var.router_lambda_function_name}"
  cloudtrail_rule_name       = var.cloudtrail_event_rule_name != "" ? var.cloudtrail_event_rule_name : "${var.name_prefix}-audit-cloudtrail-candidates"
  eks_subscription_name      = var.eks_audit_subscription_filter_name != "" ? var.eks_audit_subscription_filter_name : "${var.name_prefix}-audit-eks-candidates"
  dlq_name                   = var.dlq_name != "" ? var.dlq_name : "${var.name_prefix}-audit-detection-dlq"
  alert_ready_queue_name     = var.alert_ready_queue_name != "" ? var.alert_ready_queue_name : "${var.name_prefix}-audit-alert-ready"
  alert_ready_dlq_name       = var.alert_ready_dlq_name != "" ? var.alert_ready_dlq_name : "${var.name_prefix}-audit-alert-ready-dlq"
  discord_webhook_secret     = var.discord_webhook_secret_name != "" ? var.discord_webhook_secret_name : "${var.name_prefix}-mandate11-discord-webhook"
  discord_webhook_secret_arn = var.discord_webhook_secret_arn != "" ? var.discord_webhook_secret_arn : try(aws_secretsmanager_secret.discord_webhook[0].arn, "")
  cloudtrail_target_id       = var.cloudtrail_event_target_id
  lambda_kms_key_arn         = var.lambda_kms_key_arn != "" ? var.lambda_kms_key_arn : null
  default_filter_pattern     = "{ (($.objectRef.resource = \"secrets\") && (($.verb = \"get\") || ($.verb = \"list\") || ($.verb = \"watch\") || ($.verb = \"delete\") || ($.verb = \"deletecollection\"))) || ((($.objectRef.resource = \"rolebindings\") || ($.objectRef.resource = \"clusterrolebindings\")) && (($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\"))) || (($.objectRef.resource = \"pods\") && (($.objectRef.subresource = \"exec\") || ($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\"))) || ((($.objectRef.resource = \"deployments\") || ($.objectRef.resource = \"statefulsets\") || ($.objectRef.resource = \"daemonsets\") || ($.objectRef.resource = \"jobs\") || ($.objectRef.resource = \"cronjobs\") || ($.objectRef.resource = \"services\") || ($.objectRef.resource = \"ingresses\") || ($.objectRef.resource = \"configmaps\")) && (($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\") || ($.verb = \"delete\") || ($.verb = \"deletecollection\"))) }"
  eks_filter_pattern         = var.eks_audit_filter_pattern != "" ? var.eks_audit_filter_pattern : local.default_filter_pattern
  ttd_dashboard_name         = var.ttd_dashboard_name != "" ? var.ttd_dashboard_name : "${var.name_prefix}-mandate11-ttd"

  lambda_environment = merge(
    {
      AUDIT_PIPELINE_VERSION = "mandate-11.2"
      CLUSTER_NAME           = var.cluster_name
    },
    var.lambda_environment_variables,
  )
}

resource "aws_sqs_queue" "audit_detection_dlq" {
  count = local.create ? 1 : 0

  name                      = local.dlq_name
  message_retention_seconds = 1209600
  kms_master_key_id         = local.lambda_kms_key_arn
  sqs_managed_sse_enabled   = local.lambda_kms_key_arn == null ? true : null

  tags = merge(var.tags, {
    Name    = local.dlq_name
    Mandate = "11.2"
    Purpose = "audit-detection-dlq"
  })
}

resource "aws_sqs_queue" "alert_ready_dlq" {
  count = local.router_enabled ? 1 : 0

  name                      = local.alert_ready_dlq_name
  message_retention_seconds = 1209600
  kms_master_key_id         = local.lambda_kms_key_arn
  sqs_managed_sse_enabled   = local.lambda_kms_key_arn == null ? true : null

  tags = merge(var.tags, {
    Name    = local.alert_ready_dlq_name
    Mandate = "11.4"
    Purpose = "audit-alert-router-dlq"
  })
}

resource "aws_sqs_queue" "alert_ready" {
  count = local.router_enabled ? 1 : 0

  name                       = local.alert_ready_queue_name
  message_retention_seconds  = var.alert_ready_queue_message_retention_seconds
  visibility_timeout_seconds = var.alert_ready_queue_visibility_timeout_seconds
  kms_master_key_id          = local.lambda_kms_key_arn
  sqs_managed_sse_enabled    = local.lambda_kms_key_arn == null ? true : null

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.alert_ready_dlq[0].arn
    maxReceiveCount     = var.alert_ready_queue_max_receive_count
  })

  tags = merge(var.tags, {
    Name    = local.alert_ready_queue_name
    Mandate = "11.4"
    Purpose = "audit-alert-ready-router"
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "alert_ready_dlq" {
  count = local.router_enabled ? 1 : 0

  queue_url = aws_sqs_queue.alert_ready_dlq[0].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.alert_ready[0].arn]
  })
}

data "aws_iam_policy_document" "alert_ready_queue" {
  count = local.router_enabled ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.alert_ready[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "alert_ready_dlq" {
  count = local.router_enabled ? 1 : 0

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.alert_ready_dlq[0].arn]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "alert_ready" {
  count = local.router_enabled ? 1 : 0

  queue_url = aws_sqs_queue.alert_ready[0].url
  policy    = data.aws_iam_policy_document.alert_ready_queue[0].json
}

resource "aws_sqs_queue_policy" "alert_ready_dlq" {
  count = local.router_enabled ? 1 : 0

  queue_url = aws_sqs_queue.alert_ready_dlq[0].url
  policy    = data.aws_iam_policy_document.alert_ready_dlq[0].json
}

data "aws_iam_policy_document" "lambda_assume" {
  count = local.create ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "parser" {
  count = local.create ? 1 : 0

  name               = local.lambda_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "parser" {
  count = local.create ? 1 : 0

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.parser[0].arn}:*"]
  }

  statement {
    sid       = "SendFailedEventsToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.audit_detection_dlq[0].arn]
  }

  dynamic "statement" {
    for_each = local.router_enabled ? [aws_sqs_queue.alert_ready[0].arn] : []

    content {
      sid       = "SendAlertReadyMessages"
      actions   = ["sqs:SendMessage"]
      resources = [statement.value]
    }
  }

  dynamic "statement" {
    for_each = local.lambda_kms_key_arn != null ? [local.lambda_kms_key_arn] : []

    content {
      sid = "UseAuditDetectionKmsKey"
      actions = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
      ]
      resources = [statement.value]
    }
  }

  statement {
    sid = "WriteXrayTrace"
    actions = [
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "parser" {
  count = local.create ? 1 : 0

  name   = local.lambda_policy_name
  role   = aws_iam_role.parser[0].id
  policy = data.aws_iam_policy_document.parser[0].json
}

resource "aws_cloudwatch_log_group" "parser" {
  count = local.create ? 1 : 0

  name              = local.lambda_log_group_name
  retention_in_days = var.lambda_log_retention_days

  tags = merge(var.tags, {
    Name    = local.lambda_log_group_name
    Mandate = "11.2"
    Purpose = "audit-alert-parser-logs"
  })
}

resource "aws_lambda_function" "parser" {
  count = local.create ? 1 : 0

  #checkov:skip=CKV_AWS_272:Code signing requires a team-approved signing profile and CI artifact signing flow before production enforcement.
  function_name    = var.lambda_function_name
  description      = "Mandate 11 audit alert parser target. Task 11.3 CI/CD replaces the placeholder package with parser code."
  role             = aws_iam_role.parser[0].arn
  handler          = "audit_alert_parser.handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.parser_placeholder[0].output_path
  source_code_hash = data.archive_file.parser_placeholder[0].output_base64sha256
  kms_key_arn      = local.lambda_kms_key_arn
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb

  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  dead_letter_config {
    target_arn = aws_sqs_queue.audit_detection_dlq[0].arn
  }

  environment {
    variables = merge(
      local.lambda_environment,
      local.router_enabled ? {
        ALERT_READY_QUEUE_URL = aws_sqs_queue.alert_ready[0].url
      } : {},
    )
  }

  tracing_config {
    mode = var.lambda_tracing_mode
  }

  # Infra owns the Lambda shell, IAM, DLQ, and event sources. The parser package
  # is deployed by the platform pipeline, so Terraform must not roll it back to
  # the placeholder zip after the real 11.3 code is published.
  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
    ]
  }

  depends_on = [
    aws_cloudwatch_log_group.parser,
    aws_iam_role_policy.parser,
  ]

  tags = merge(var.tags, {
    Name    = var.lambda_function_name
    Mandate = "11.2-11.3"
    Purpose = "audit-alert-parser"
  })
}

resource "aws_secretsmanager_secret" "discord_webhook" {
  count = local.router_enabled && var.discord_webhook_secret_arn == "" ? 1 : 0

  name        = local.discord_webhook_secret
  description = "Discord webhook URL for Mandate 11.4 audit detection alerts. Secret value is bootstrapped outside Terraform state."
  kms_key_id  = local.lambda_kms_key_arn

  tags = merge(var.tags, {
    Name    = local.discord_webhook_secret
    Mandate = "11.4"
    Purpose = "audit-alert-discord-webhook"
  })
}

resource "aws_iam_role" "router" {
  count = local.router_enabled ? 1 : 0

  name               = local.router_lambda_role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "router" {
  count = local.router_enabled ? 1 : 0

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.router[0].arn}:*"]
  }

  statement {
    sid     = "ReadDiscordWebhook"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      local.discord_webhook_secret_arn,
    ]
  }

  statement {
    sid = "ConsumeAlertReadyQueue"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.alert_ready[0].arn]
  }

  statement {
    sid       = "SendRouterFailuresToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.alert_ready_dlq[0].arn]
  }

  dynamic "statement" {
    for_each = local.lambda_kms_key_arn != null ? [local.lambda_kms_key_arn] : []

    content {
      sid = "UseAuditDetectionKmsKey"
      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey",
      ]
      resources = [statement.value]
    }
  }

  statement {
    sid = "WriteXrayTrace"
    actions = [
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "router" {
  count = local.router_enabled ? 1 : 0

  name   = local.router_lambda_policy_name
  role   = aws_iam_role.router[0].id
  policy = data.aws_iam_policy_document.router[0].json
}

resource "aws_cloudwatch_log_group" "router" {
  count = local.router_enabled ? 1 : 0

  name              = local.router_lambda_log_group
  retention_in_days = var.lambda_log_retention_days

  tags = merge(var.tags, {
    Name    = local.router_lambda_log_group
    Mandate = "11.4-11.5"
    Purpose = "audit-alert-router-logs"
  })
}

resource "aws_lambda_function" "router" {
  #checkov:skip=CKV_AWS_50:CloudWatch Logs, EMF metrics, alarms, SQS retry, and DLQ cover this low-volume alert path; X-Ray can be enabled with lambda_tracing_mode after cost approval.
  #checkov:skip=CKV_AWS_117:Discord webhook delivery requires public egress; keeping the router outside VPC avoids NAT dependency for the audit alert path.
  #checkov:skip=CKV_AWS_272:Code signing requires a team-approved signing profile and CI artifact signing flow before production enforcement.
  count = local.router_enabled ? 1 : 0

  function_name    = var.router_lambda_function_name
  description      = "Mandate 11.4 SQS-to-Discord audit alert router. Platform CI/CD replaces the placeholder package with router code."
  role             = aws_iam_role.router[0].arn
  handler          = "audit_alert_router.handler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.router_placeholder[0].output_path
  source_code_hash = data.archive_file.router_placeholder[0].output_base64sha256
  kms_key_arn      = local.lambda_kms_key_arn
  timeout          = var.router_lambda_timeout_seconds
  memory_size      = var.router_lambda_memory_mb

  reserved_concurrent_executions = var.router_lambda_reserved_concurrent_executions

  dead_letter_config {
    target_arn = aws_sqs_queue.alert_ready_dlq[0].arn
  }

  environment {
    variables = {
      AUDIT_DETECTION_EVIDENCE_NAMESPACE = var.ttd_metric_namespace
      DISCORD_MAX_CONTENT_CHARS          = tostring(var.discord_max_content_chars)
      DISCORD_WEBHOOK_SECRET_ARN         = local.discord_webhook_secret_arn
    }
  }

  tracing_config {
    mode = var.lambda_tracing_mode
  }

  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
    ]
  }

  depends_on = [
    aws_cloudwatch_log_group.router,
    aws_iam_role_policy.router,
  ]

  tags = merge(var.tags, {
    Name    = var.router_lambda_function_name
    Mandate = "11.4-11.5"
    Purpose = "audit-alert-discord-router"
  })
}

resource "aws_lambda_event_source_mapping" "alert_ready_to_router" {
  count = local.router_enabled ? 1 : 0

  event_source_arn        = aws_sqs_queue.alert_ready[0].arn
  function_name           = aws_lambda_function.router[0].arn
  batch_size              = var.router_event_source_batch_size
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_cloudwatch_event_rule" "cloudtrail_candidates" {
  count = local.create ? 1 : 0

  name        = local.cloudtrail_rule_name
  description = "Mandate 11.2 coarse CloudTrail filter. Forwards raw candidate events to the 11.3 parser Lambda."
  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      "$or" = [
        {
          eventSource = ["iam.amazonaws.com"]
          eventName   = sort(tolist(var.cloudtrail_iam_event_names))
        },
        {
          eventSource = ["eks.amazonaws.com"]
          eventName   = sort(tolist(var.cloudtrail_eks_event_names))
        },
        {
          eventSource = ["cloudtrail.amazonaws.com"]
          eventName   = sort(tolist(var.cloudtrail_audit_event_names))
        },
      ]
    }
  })

  tags = merge(var.tags, {
    Name    = local.cloudtrail_rule_name
    Mandate = "11.2"
    Purpose = "cloudtrail-audit-candidate-filter"
  })
}

resource "aws_lambda_permission" "eventbridge" {
  count = local.create ? 1 : 0

  statement_id  = "AllowMandate11CloudTrailEventBridgeDirect"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parser[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cloudtrail_candidates[0].arn
}

data "aws_iam_policy_document" "dlq" {
  count = local.create ? 1 : 0

  statement {
    sid     = "AllowEventBridgeSendFailedEvents"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sqs_queue.audit_detection_dlq[0].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.cloudtrail_candidates[0].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  count = local.create ? 1 : 0

  queue_url = aws_sqs_queue.audit_detection_dlq[0].id
  policy    = data.aws_iam_policy_document.dlq[0].json
}

resource "aws_cloudwatch_event_target" "cloudtrail_to_parser" {
  count = local.create ? 1 : 0

  rule      = aws_cloudwatch_event_rule.cloudtrail_candidates[0].name
  target_id = local.cloudtrail_target_id
  arn       = aws_lambda_function.parser[0].arn

  dead_letter_config {
    arn = aws_sqs_queue.audit_detection_dlq[0].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = var.eventbridge_maximum_event_age_seconds
    maximum_retry_attempts       = var.eventbridge_maximum_retry_attempts
  }

  depends_on = [
    aws_lambda_permission.eventbridge,
    aws_sqs_queue_policy.dlq,
  ]
}

resource "aws_lambda_permission" "eks_audit_logs" {
  count = local.create ? 1 : 0

  statement_id  = "AllowMandate11EksAuditLogsDirect"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parser[0].function_name
  principal     = "logs.${local.region}.amazonaws.com"
  source_arn    = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.audit_log_group}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "eks_audit_candidates" {
  count = local.create ? 1 : 0

  name            = local.eks_subscription_name
  log_group_name  = local.audit_log_group
  filter_pattern  = local.eks_filter_pattern
  destination_arn = aws_lambda_function.parser[0].arn

  depends_on = [aws_lambda_permission.eks_audit_logs]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = local.create && var.enable_alarms ? 1 : 0

  alarm_name          = "${var.lambda_function_name}-errors"
  alarm_description   = "Mandate 11 parser Lambda has errors; audit detection may miss dangerous activity."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.parser[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count = local.create && var.enable_alarms ? 1 : 0

  alarm_name          = "${var.lambda_function_name}-throttles"
  alarm_description   = "Mandate 11 parser Lambda is throttling; audit detection latency can increase."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.parser[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "eventbridge_failed_invocations" {
  count = local.create && var.enable_alarms ? 1 : 0

  alarm_name          = "${local.cloudtrail_rule_name}-failed-invocations"
  alarm_description   = "EventBridge failed to invoke the Mandate 11 parser for CloudTrail candidates."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedInvocations"
  namespace           = "AWS/Events"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    RuleName = aws_cloudwatch_event_rule.cloudtrail_candidates[0].name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_visible_messages" {
  count = local.create && var.enable_alarms ? 1 : 0

  alarm_name          = "${local.dlq_name}-visible-messages"
  alarm_description   = "Mandate 11 audit detection DLQ has messages that require replay or investigation."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    QueueName = aws_sqs_queue.audit_detection_dlq[0].name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "router_errors" {
  count = local.router_enabled && var.enable_alarms ? 1 : 0

  alarm_name          = "${var.router_lambda_function_name}-errors"
  alarm_description   = "Mandate 11 Discord router Lambda has errors; Discord alert delivery can be delayed."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.router[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "router_throttles" {
  count = local.router_enabled && var.enable_alarms ? 1 : 0

  alarm_name          = "${var.router_lambda_function_name}-throttles"
  alarm_description   = "Mandate 11 Discord router Lambda is throttling; audit alert TTD can increase."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    FunctionName = aws_lambda_function.router[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alert_ready_dlq_visible_messages" {
  count = local.router_enabled && var.enable_alarms ? 1 : 0

  alarm_name          = "${local.alert_ready_dlq_name}-visible-messages"
  alarm_description   = "Mandate 11 Discord router DLQ has undelivered alert-ready messages."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    QueueName = aws_sqs_queue.alert_ready_dlq[0].name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "discord_delivery_failures" {
  count = local.router_enabled && var.enable_alarms ? 1 : 0

  alarm_name          = "${var.router_lambda_function_name}-discord-delivery-failures"
  alarm_description   = "Mandate 11 Discord router emitted delivery failure evidence."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "DiscordDeliveryFailure"
  namespace           = var.ttd_metric_namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    Pipeline = "audit-detection"
    Channel  = "discord"
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "end_to_end_ttd_high" {
  count = local.router_enabled && var.enable_alarms ? 1 : 0

  alarm_name          = "${var.router_lambda_function_name}-ttd-high"
  alarm_description   = "Mandate 11 end-to-end time-to-detect to Discord exceeded the approved threshold."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EndToEndTTDSeconds"
  namespace           = var.ttd_metric_namespace
  period              = 300
  statistic           = "Maximum"
  threshold           = var.ttd_threshold_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns

  dimensions = {
    Pipeline = "audit-detection"
    Channel  = "discord"
  }

  tags = var.tags
}

resource "aws_cloudwatch_dashboard" "ttd" {
  count = local.router_enabled && var.enable_ttd_dashboard ? 1 : 0

  dashboard_name = local.ttd_dashboard_name
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          markdown = join("\n", [
            "# Mandate 11 Audit Detection TTD",
            "Flow: CloudTrail/EKS audit -> parser Lambda -> SQS alert-ready -> Discord router Lambda -> Discord.",
            "Webhook values are stored in Secrets Manager and must not appear in dashboards, logs, Terraform variables, or PR comments.",
          ])
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 12
        height = 6
        properties = {
          region = local.region
          title  = "End-to-end TTD to Discord"
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            [
              var.ttd_metric_namespace,
              "EndToEndTTDSeconds",
              "Pipeline",
              "audit-detection",
              "Channel",
              "discord",
              { stat = "Average", label = "Avg TTD seconds" },
            ],
            [
              ".",
              ".",
              ".",
              ".",
              ".",
              ".",
              { stat = "Maximum", label = "Max TTD seconds" },
            ],
          ]
          annotations = {
            horizontal = [
              {
                label = "TTD threshold"
                value = var.ttd_threshold_seconds
              }
            ]
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 3
        width  = 12
        height = 6
        properties = {
          region = local.region
          title  = "Discord delivery success/failure"
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            [
              var.ttd_metric_namespace,
              "DiscordDeliverySuccess",
              "Pipeline",
              "audit-detection",
              "Channel",
              "discord",
            ],
            [
              ".",
              "DiscordDeliveryFailure",
              ".",
              ".",
              ".",
              ".",
            ],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 9
        width  = 12
        height = 6
        properties = {
          region = local.region
          title  = "Parser and router Lambda health"
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", aws_lambda_function.parser[0].function_name],
            [".", "Throttles", ".", "."],
            [".", "Errors", ".", aws_lambda_function.router[0].function_name],
            [".", "Throttles", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 9
        width  = 12
        height = 6
        properties = {
          region = local.region
          title  = "Alert-ready queue and DLQ depth"
          view   = "timeSeries"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.alert_ready[0].name],
            [".", ".", ".", aws_sqs_queue.alert_ready_dlq[0].name],
          ]
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 15
        width  = 24
        height = 8
        properties = {
          region = local.region
          title  = "Latest Mandate 11 evidence records"
          query = join(" | ", [
            "SOURCE '${local.lambda_log_group_name}'",
            "SOURCE '${local.router_lambda_log_group}'",
            "fields @timestamp, status, delivery_status, rule_id, severity, actor, action, time_to_alert_ready_seconds, router_latency_seconds, end_to_end_ttd_seconds",
            "filter event = 'audit_detection_evidence'",
            "sort @timestamp desc",
            "limit 50",
          ])
        }
      },
    ]
  })
}
