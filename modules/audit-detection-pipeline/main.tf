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
  output_path = "${path.module}/lambda/audit_alert_parser_placeholder.zip"
}

locals {
  create = var.enabled

  account_id      = local.create ? data.aws_caller_identity.current[0].account_id : "000000000000"
  partition       = local.create ? data.aws_partition.current[0].partition : "aws"
  region          = local.create ? data.aws_region.current[0].name : "us-east-1"
  audit_log_group = var.audit_log_group_name != "" ? var.audit_log_group_name : "/aws/eks/${var.cluster_name}/cluster"

  lambda_role_name       = "${var.name_prefix}-audit-alert-parser"
  lambda_log_group_name  = "/aws/lambda/${var.lambda_function_name}"
  cloudtrail_rule_name   = "${var.name_prefix}-audit-cloudtrail-candidates"
  eks_subscription_name  = "${var.name_prefix}-audit-eks-candidates"
  dlq_name               = "${var.name_prefix}-audit-detection-dlq"
  cloudtrail_target_id   = "audit-alert-parser"
  default_filter_pattern = "{ (($.objectRef.resource = \"secrets\") && (($.verb = \"get\") || ($.verb = \"list\") || ($.verb = \"watch\") || ($.verb = \"delete\") || ($.verb = \"deletecollection\"))) || ((($.objectRef.resource = \"rolebindings\") || ($.objectRef.resource = \"clusterrolebindings\")) && (($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\"))) || (($.objectRef.resource = \"pods\") && (($.objectRef.subresource = \"exec\") || ($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\"))) || ((($.objectRef.resource = \"deployments\") || ($.objectRef.resource = \"statefulsets\") || ($.objectRef.resource = \"daemonsets\") || ($.objectRef.resource = \"jobs\") || ($.objectRef.resource = \"cronjobs\") || ($.objectRef.resource = \"services\") || ($.objectRef.resource = \"ingresses\") || ($.objectRef.resource = \"configmaps\")) && (($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\") || ($.verb = \"delete\") || ($.verb = \"deletecollection\"))) }"
  eks_filter_pattern     = var.eks_audit_filter_pattern != "" ? var.eks_audit_filter_pattern : local.default_filter_pattern

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
  sqs_managed_sse_enabled   = true

  tags = merge(var.tags, {
    Name    = local.dlq_name
    Mandate = "11.2"
    Purpose = "audit-detection-dlq"
  })
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

  name   = "${local.lambda_role_name}-policy"
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
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb

  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  dead_letter_config {
    target_arn = aws_sqs_queue.audit_detection_dlq[0].arn
  }

  environment {
    variables = local.lambda_environment
  }

  tracing_config {
    mode = "Active"
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

resource "aws_cloudwatch_event_rule" "cloudtrail_candidates" {
  count = local.create ? 1 : 0

  name        = local.cloudtrail_rule_name
  description = "Mandate 11.2 coarse CloudTrail filter. Forwards raw candidate events to the 11.3 parser Lambda."
  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = sort(tolist(var.cloudtrail_event_sources))
      eventName   = sort(tolist(var.cloudtrail_event_names))
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

  statement_id  = "AllowExecutionFromMandate11CloudTrailRule"
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

  statement_id  = "AllowExecutionFromMandate11EksAuditLogs"
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

