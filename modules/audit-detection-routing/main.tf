locals {
  create                      = var.enabled
  function_name               = "${var.name_prefix}-audit-alert-router"
  queue_name                  = "${var.name_prefix}-audit-alert-routing"
  dlq_name                    = "${var.name_prefix}-audit-alert-routing-dlq"
  cloudtrail_rule_name        = "${var.name_prefix}-dangerous-cloudtrail-api"
  kubernetes_audit_log_group  = coalesce(var.kubernetes_audit_log_group_name, "/aws/eks/${var.cluster_name}/cluster")
  lambda_source_dir           = "${path.module}/lambda"
  lambda_package_path         = "${path.root}/.terraform/${local.function_name}.zip"
  allowed_aws_principals_json = jsonencode(var.allowed_aws_principal_arn_patterns)
  allowed_k8s_users_json      = jsonencode(var.allowed_kubernetes_user_patterns)
  production_namespaces_json  = jsonencode(var.production_namespace_patterns)
  cloudtrail_event_sources    = ["iam.amazonaws.com", "eks.amazonaws.com", "cloudtrail.amazonaws.com"]
}

data "archive_file" "lambda" {
  count = local.create ? 1 : 0

  type        = "zip"
  source_dir  = local.lambda_source_dir
  output_path = local.lambda_package_path
}

data "aws_iam_policy_document" "lambda_assume_role" {
  count = local.create ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  count = local.create ? 1 : 0

  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role[0].json
  tags               = var.tags
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = local.create ? 1 : 0

  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_sqs_queue" "dlq" {
  count = local.create ? 1 : 0

  name                      = local.dlq_name
  message_retention_seconds = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "routing" {
  count = local.create ? 1 : 0

  name                       = local.queue_name
  message_retention_seconds  = var.sqs_message_retention_seconds
  visibility_timeout_seconds = var.sqs_visibility_timeout_seconds
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = var.sqs_max_receive_count
  })
  tags = var.tags
}

data "aws_iam_policy_document" "lambda" {
  count = local.create ? 1 : 0

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.lambda[0].arn}:*"]
  }

  statement {
    sid       = "ReadDiscordWebhookSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:*:*:secret:${var.discord_webhook_secret_name}*"]
  }

  statement {
    sid = "InspectIamPoliciesForNoiseReduction"
    actions = [
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
    ]
    resources = ["*"]
  }

  statement {
    sid = "ConsumeAuditRoutingQueue"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.routing[0].arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  count = local.create ? 1 : 0

  name   = "${local.function_name}-policy"
  role   = aws_iam_role.lambda[0].id
  policy = data.aws_iam_policy_document.lambda[0].json
}

resource "aws_lambda_function" "router" {
  count = local.create ? 1 : 0

  function_name    = local.function_name
  description      = "Routes high-signal audit/security events to Discord with actor/action/source/TTD context."
  role             = aws_iam_role.lambda[0].arn
  handler          = "audit_alert_router.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda[0].output_path
  source_code_hash = data.archive_file.lambda[0].output_base64sha256
  timeout          = 20
  memory_size      = 256
  tags             = var.tags

  environment {
    variables = {
      ALLOWED_AWS_PRINCIPAL_ARN_PATTERNS = local.allowed_aws_principals_json
      ALLOWED_KUBERNETES_USER_PATTERNS   = local.allowed_k8s_users_json
      CLUSTER_NAME                       = var.cluster_name
      DISCORD_WEBHOOK_SECRET_JSON_KEY    = var.discord_webhook_secret_json_key
      DISCORD_WEBHOOK_SECRET_NAME        = var.discord_webhook_secret_name
      ENVIRONMENT                        = var.environment
      PRODUCTION_NAMESPACE_PATTERNS      = local.production_namespaces_json
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]
}

resource "aws_cloudwatch_event_rule" "cloudtrail_dangerous_api" {
  count = local.create ? 1 : 0

  name        = local.cloudtrail_rule_name
  description = "Forwards selected dangerous CloudTrail management events to the audit alert router."
  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = local.cloudtrail_event_sources
      eventName   = tolist(var.cloudtrail_event_names)
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "cloudtrail_dangerous_api" {
  count = local.create ? 1 : 0

  rule      = aws_cloudwatch_event_rule.cloudtrail_dangerous_api[0].name
  target_id = "audit-alert-routing-queue"
  arn       = aws_sqs_queue.routing[0].arn
}

data "aws_iam_policy_document" "eventbridge_sqs" {
  count = local.create ? 1 : 0

  statement {
    sid     = "AllowEventBridgeDangerousApiSendMessage"
    actions = ["sqs:SendMessage"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sqs_queue.routing[0].arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.cloudtrail_dangerous_api[0].arn]
    }
  }
}

resource "aws_sqs_queue_policy" "eventbridge" {
  count = local.create ? 1 : 0

  queue_url = aws_sqs_queue.routing[0].id
  policy    = data.aws_iam_policy_document.eventbridge_sqs[0].json
}

resource "aws_lambda_event_source_mapping" "sqs" {
  count = local.create ? 1 : 0

  event_source_arn = aws_sqs_queue.routing[0].arn
  function_name    = aws_lambda_function.router[0].arn
  batch_size       = var.sqs_lambda_batch_size
  enabled          = true

  scaling_config {
    maximum_concurrency = var.sqs_maximum_concurrency
  }
}

resource "aws_cloudwatch_log_subscription_filter" "kubernetes_audit" {
  count = local.create && var.kubernetes_audit_enabled ? 1 : 0

  name            = "${var.name_prefix}-kubernetes-audit-dangerous-actions"
  log_group_name  = local.kubernetes_audit_log_group
  filter_pattern  = "{ ($.verb = create) || ($.verb = update) || ($.verb = patch) || ($.verb = delete) || ($.verb = deletecollection) || ($.verb = get) || ($.verb = list) || ($.verb = watch) }"
  destination_arn = aws_lambda_function.router[0].arn

  depends_on = [aws_lambda_permission.cloudwatch_logs]
}

resource "aws_lambda_permission" "cloudwatch_logs" {
  count = local.create && var.kubernetes_audit_enabled ? 1 : 0

  statement_id  = "AllowExecutionFromCloudWatchLogsKubernetesAudit"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router[0].function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:aws:logs:*:*:log-group:${local.kubernetes_audit_log_group}:*"
}
