data "aws_caller_identity" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = var.enabled ? 1 : 0
}

data "aws_region" "current" {
  count = var.enabled ? 1 : 0
}

data "archive_file" "audit_classifier" {
  count = var.enabled ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/lambda/audit_classifier.py"
  output_path = "${path.module}/lambda/audit_classifier.zip"
}

locals {
  create = var.enabled

  topic_name               = "${var.name_prefix}-runtime-security-alerts"
  audit_classifier_name    = "${var.name_prefix}-runtime-audit-classifier"
  audit_classifier_log     = "/aws/lambda/${local.audit_classifier_name}"
  audit_classifier_dlq     = "${local.audit_classifier_name}-dlq"
  audit_classifier_sg_name = "${local.audit_classifier_name}-sg"
  kms_alias_name           = "alias/${var.name_prefix}-runtime-security-alerting"
  guardduty_rule_name      = "${var.name_prefix}-guardduty-runtime-security"
  node_role_rule_name      = "${var.name_prefix}-node-role-runtime-security"
  partition                = local.create ? data.aws_partition.current[0].partition : "aws"
  account_id               = local.create ? data.aws_caller_identity.current[0].account_id : "000000000000"
  node_role_arns           = [for arn in var.node_role_arns : arn if arn != ""]
  enable_node_role_rule    = local.create && var.enable_node_role_anomaly_events && length(local.node_role_arns) > 0
  enable_guardduty_rule    = local.create && var.enable_guardduty_eventbridge
  sanitized_vap_names_json = jsonencode(sort(tolist(var.vap_policy_names)))
}

data "aws_iam_policy_document" "runtime_security_kms" {
  count = local.create ? 1 : 0

  statement {
    sid = "AllowAccountKeyAdministration"
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid = "AllowCloudWatchLogsEncryption"
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current[0].name}.amazonaws.com"]
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${data.aws_region.current[0].name}:${local.account_id}:log-group:${local.audit_classifier_log}"]
    }
  }
}

resource "aws_kms_key" "runtime_security" {
  count = local.create ? 1 : 0

  description             = "Encrypt runtime security alerting Lambda environment, logs, and DLQ."
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.runtime_security_kms[0].json

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-runtime-security-alerting"
  })
}

resource "aws_kms_alias" "runtime_security" {
  count = local.create ? 1 : 0

  name          = local.kms_alias_name
  target_key_id = aws_kms_key.runtime_security[0].key_id
}

resource "aws_sns_topic" "runtime_security" {
  count = local.create ? 1 : 0

  name              = local.topic_name
  kms_master_key_id = "alias/aws/sns"

  tags = merge(var.tags, {
    Name = local.topic_name
  })
}

resource "aws_sns_topic_policy" "runtime_security" {
  count = local.create ? 1 : 0

  arn = aws_sns_topic.runtime_security[0].arn

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "${local.topic_name}-publish"
    Statement = [
      {
        Sid    = "AllowAccountOwnerManageTopic"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${local.partition}:iam::${local.account_id}:root"
        }
        Action   = "SNS:*"
        Resource = aws_sns_topic.runtime_security[0].arn
      },
      {
        Sid    = "AllowAwsServicesPublish"
        Effect = "Allow"
        Principal = {
          Service = [
            "cloudwatch.amazonaws.com",
            "events.amazonaws.com",
          ]
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.runtime_security[0].arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = local.account_id
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email_json" {
  count = local.create && var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.runtime_security[0].arn
  protocol  = "email-json"
  endpoint  = var.alert_email
}

resource "aws_sqs_queue" "audit_classifier_dlq" {
  count = local.create ? 1 : 0

  name                              = local.audit_classifier_dlq
  kms_master_key_id                 = aws_kms_key.runtime_security[0].arn
  kms_data_key_reuse_period_seconds = 300
  message_retention_seconds         = 1209600

  tags = merge(var.tags, {
    Name = local.audit_classifier_dlq
  })
}

resource "aws_security_group" "audit_classifier" {
  count = local.create ? 1 : 0

  name        = local.audit_classifier_sg_name
  description = "Runtime audit classifier Lambda egress"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = local.audit_classifier_sg_name
  })
}

resource "aws_vpc_security_group_egress_rule" "audit_classifier_https" {
  count = local.create ? 1 : 0

  security_group_id = aws_security_group.audit_classifier[0].id
  description       = "Allow HTTPS egress for AWS APIs through private subnet NAT or endpoints."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, {
    Name = "${local.audit_classifier_sg_name}-https-egress"
  })
}

data "aws_iam_policy_document" "audit_classifier_assume" {
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

resource "aws_iam_role" "audit_classifier" {
  count = local.create ? 1 : 0

  name               = local.audit_classifier_name
  assume_role_policy = data.aws_iam_policy_document.audit_classifier_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "audit_classifier" {
  count = local.create ? 1 : 0

  statement {
    sid = "WriteOwnLogs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.audit_classifier[0].arn}:*"]
  }

  statement {
    sid       = "PublishRuntimeSecurityAlert"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.runtime_security[0].arn]
  }

  statement {
    sid = "SendFailedEventsToDlq"
    actions = [
      "sqs:SendMessage",
    ]
    resources = [aws_sqs_queue.audit_classifier_dlq[0].arn]
  }

  statement {
    sid = "UseRuntimeSecurityKms"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.runtime_security[0].arn]
  }

  statement {
    sid = "WriteXrayTrace"
    actions = [
      "xray:PutTelemetryRecords",
      "xray:PutTraceSegments",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EmitClassifierMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["TechX/RuntimeSecurity"]
    }
  }
}

resource "aws_iam_role_policy" "audit_classifier" {
  count = local.create ? 1 : 0

  name   = "${local.audit_classifier_name}-policy"
  role   = aws_iam_role.audit_classifier[0].id
  policy = data.aws_iam_policy_document.audit_classifier[0].json
}

resource "aws_iam_role_policy_attachment" "audit_classifier_vpc_access" {
  count = local.create ? 1 : 0

  role       = aws_iam_role.audit_classifier[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "audit_classifier" {
  count = local.create ? 1 : 0

  name              = local.audit_classifier_log
  retention_in_days = 30
  kms_key_id        = aws_kms_key.runtime_security[0].arn
  tags              = var.tags
}

resource "aws_lambda_function" "audit_classifier" {
  count = local.create ? 1 : 0

  #checkov:skip=CKV_AWS_272:Code signing requires an approved signing profile and CI artifact signing step before promotion.
  function_name    = local.audit_classifier_name
  description      = "Classify sanitized Kubernetes runtime-hardening admission denies from EKS audit logs."
  role             = aws_iam_role.audit_classifier[0].arn
  handler          = "audit_classifier.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.audit_classifier[0].output_path
  source_code_hash = data.archive_file.audit_classifier[0].output_base64sha256
  timeout          = var.lambda_timeout_seconds
  memory_size      = var.lambda_memory_mb
  kms_key_arn      = aws_kms_key.runtime_security[0].arn

  reserved_concurrent_executions = var.lambda_reserved_concurrent_executions

  dead_letter_config {
    target_arn = aws_sqs_queue.audit_classifier_dlq[0].arn
  }

  environment {
    variables = {
      CLUSTER_NAME          = var.cluster_name
      DEDUPE_WINDOW_SECONDS = tostring(var.dedupe_window_seconds)
      RUNTIME_SNS_TOPIC_ARN = aws_sns_topic.runtime_security[0].arn
      VAP_POLICY_NAMES_JSON = local.sanitized_vap_names_json
    }
  }

  tracing_config {
    mode = "Active"
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.audit_classifier[0].id]
  }

  depends_on = [
    aws_cloudwatch_log_group.audit_classifier,
    aws_iam_role_policy.audit_classifier,
    aws_iam_role_policy_attachment.audit_classifier_vpc_access,
  ]
  tags = var.tags
}

resource "aws_lambda_permission" "audit_logs" {
  count = local.create ? 1 : 0

  statement_id  = "AllowExecutionFromEksAuditLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_classifier[0].function_name
  principal     = "logs.amazonaws.com"
  source_arn    = "arn:${local.partition}:logs:${data.aws_region.current[0].name}:${local.account_id}:log-group:${var.audit_log_group_name}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "eks_audit_denies" {
  count = local.create ? 1 : 0

  name            = "${var.name_prefix}-runtime-hardening-denies"
  log_group_name  = var.audit_log_group_name
  filter_pattern  = var.audit_filter_pattern
  destination_arn = aws_lambda_function.audit_classifier[0].arn

  depends_on = [aws_lambda_permission.audit_logs]
}

resource "aws_cloudwatch_metric_alarm" "audit_classifier_errors" {
  count = local.create ? 1 : 0

  alarm_name          = "${local.audit_classifier_name}-errors"
  alarm_description   = "Runtime audit classifier Lambda has errors; runtime-security deny alerting may be blind."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.runtime_security[0].arn]
  ok_actions          = [aws_sns_topic.runtime_security[0].arn]

  dimensions = {
    FunctionName = aws_lambda_function.audit_classifier[0].function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "audit_classifier_no_processed_events" {
  count = local.create && var.enable_classifier_deadman_alarm ? 1 : 0

  alarm_name          = "${local.audit_classifier_name}-no-processed-events"
  alarm_description   = "No EKS audit events were processed by runtime audit classifier for 30 minutes. Check log subscription health before relying on deny alerting."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 6
  metric_name         = "ProcessedAuditLogBatches"
  namespace           = "TechX/RuntimeSecurity"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.runtime_security[0].arn]
  ok_actions          = [aws_sns_topic.runtime_security[0].arn]

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "guardduty_runtime" {
  count = local.enable_guardduty_rule ? 1 : 0

  name        = local.guardduty_rule_name
  description = "Route GuardDuty High/Critical EKS/runtime findings to runtime security SNS."
  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 7] }]
      service = {
        resourceRole = ["TARGET"]
      }
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "guardduty_runtime_sns" {
  count = local.enable_guardduty_rule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_runtime[0].name
  target_id = "runtime-security-sns"
  arn       = aws_sns_topic.runtime_security[0].arn
}

resource "aws_cloudwatch_event_rule" "node_role_anomaly" {
  count = local.enable_node_role_rule ? 1 : 0

  name        = local.node_role_rule_name
  description = "Route selected suspicious CloudTrail events by worker-node IAM roles to runtime security SNS."
  event_pattern = jsonencode({
    source      = ["aws.cloudtrail"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = sort(tolist(var.node_role_watch_event_sources))
      userIdentity = {
        sessionContext = {
          sessionIssuer = {
            arn = local.node_role_arns
          }
        }
      }
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "node_role_anomaly_sns" {
  count = local.enable_node_role_rule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.node_role_anomaly[0].name
  target_id = "runtime-security-sns"
  arn       = aws_sns_topic.runtime_security[0].arn
}
