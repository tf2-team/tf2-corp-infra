############################################
# MANDATE-11.2 — Pipeline 2 (real-time, no S3)
#   CloudTrail -> EventBridge (Filter+Transform) -> SQS -> Alert Lambda
#   EKS Audit  -> CW Logs (Filter) -> Parse Lambda -> SQS -> Alert Lambda
#
# CloudTrail trail, CloudTrail log group, và EKS control-plane audit
# logging ĐÃ TỒN TẠI THẬT (tạo trước đó, không thuộc phạm vi module này)
# -> tham chiếu bằng `data`, KHÔNG tạo mới, tránh "already exists".
############################################

data "aws_caller_identity" "current" {}

data "aws_cloudtrail" "existing" {
  name = var.cloudtrail_name
}

data "aws_cloudwatch_log_group" "cloudtrail" {
  name = var.cloudtrail_log_group_name
}

data "aws_cloudwatch_log_group" "eks_audit" {
  name = "/aws/eks/${var.eks_cluster_name}/cluster"
}

############################################
# KMS — dùng chung cho SQS + Lambda env var encryption
############################################

resource "aws_kms_key" "audit_pipeline" {
  description             = "${var.project_name} audit pipeline v2 encryption (SQS, Lambda env vars)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_key_policy" "audit_pipeline" {
  key_id = aws_kms_key.audit_pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEventBridgeUseKey"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogsUseKey"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      },
    ]
  })
}

############################################
# SQS — queue chung cho cả 2 nhánh, + DLQ riêng
############################################

resource "aws_sqs_queue" "audit_alert_dlq" {
  name                      = "${var.project_name}-audit-alert-dlq"
  message_retention_seconds = 1209600 # 14 ngày
  kms_master_key_id         = aws_kms_key.audit_pipeline.arn
  tags                      = var.tags
}

resource "aws_sqs_queue" "audit_alert_queue" {
  name                       = "${var.project_name}-audit-alert-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 ngày
  kms_master_key_id          = aws_kms_key.audit_pipeline.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.audit_alert_dlq.arn
    maxReceiveCount     = 5
  })

  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "audit_alert_dlq" {
  queue_url = aws_sqs_queue.audit_alert_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.audit_alert_queue.arn]
  })
}

resource "aws_sqs_queue_policy" "allow_eventbridge_send" {
  queue_url = aws_sqs_queue.audit_alert_queue.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeSendMessage"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.audit_alert_queue.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.cloudtrail_high_risk.arn }
      }
    }]
  })
}

############################################
# Parse Lambda — nhánh EKS Audit
############################################

data "archive_file" "parse_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/parse_lambda"
  output_path = "${path.module}/lambda/parse_lambda.zip"
}

resource "aws_sqs_queue" "parse_lambda_dlq" {
  name                      = "${var.project_name}-parse-lambda-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.audit_pipeline.arn
  tags                      = var.tags
}

resource "aws_iam_role" "parse_lambda" {
  name = "${var.project_name}-parse-lambda-role"
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

resource "aws_iam_role_policy_attachment" "parse_lambda_basic_exec" {
  role       = aws_iam_role.parse_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "parse_lambda_sqs_send" {
  name = "${var.project_name}-parse-lambda-sqs-send"
  role = aws_iam_role.parse_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.audit_alert_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.parse_lambda_dlq.arn
      },
    ]
  })
}

resource "aws_lambda_function" "parse_lambda" {
  function_name = "techx-parse-lambda"
  role          = aws_iam_role.parse_lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.13"
  timeout       = 30

  filename         = data.archive_file.parse_lambda.output_path
  source_code_hash = data.archive_file.parse_lambda.output_base64sha256

  reserved_concurrent_executions = 5
  kms_key_arn                    = aws_kms_key.audit_pipeline.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.parse_lambda_dlq.arn
  }
  tracing_config {
    mode = "PassThrough"
  }

  environment {
    variables = {
      SQS_QUEUE_URL               = aws_sqs_queue.audit_alert_queue.url
      ALLOWED_ACTORS              = var.allowed_actors_csv
      PRODUCTION_NAMESPACE_PREFIX = var.production_namespace_prefix
    }
  }

  tags = var.tags
}

resource "aws_lambda_permission" "cwlogs_invoke_parse_lambda" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.parse_lambda.function_name
  principal     = "logs.${var.aws_region}.amazonaws.com"
  source_arn    = "${data.aws_cloudwatch_log_group.eks_audit.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "eks_audit_to_parser" {
  name            = "high-risk-k8s-events-to-parser"
  log_group_name  = data.aws_cloudwatch_log_group.eks_audit.name
  filter_pattern  = var.k8s_audit_filter_pattern
  destination_arn = aws_lambda_function.parse_lambda.arn

  depends_on = [aws_lambda_permission.cwlogs_invoke_parse_lambda]
}

############################################
# Alert Lambda — nhận từ SQS chung, hiện tại chỉ log (rỗng)
############################################

data "archive_file" "alert_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/alert_lambda"
  output_path = "${path.module}/lambda/alert_lambda.zip"
}

resource "aws_sqs_queue" "alert_lambda_dlq" {
  name                      = "${var.project_name}-alert-lambda-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.audit_pipeline.arn
  tags                      = var.tags
}

resource "aws_iam_role" "alert_lambda" {
  name = "${var.project_name}-audit-alert-parser-role"
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

resource "aws_iam_role_policy_attachment" "alert_lambda_basic_exec" {
  role       = aws_iam_role.alert_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "alert_lambda_sqs_consume" {
  name = "${var.project_name}-alert-lambda-sqs-consume"
  role = aws_iam_role.alert_lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.audit_alert_queue.arn
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.alert_lambda_dlq.arn
      },
    ]
  })
}

resource "aws_lambda_function" "alert_lambda" {
  function_name = "techx-audit-alert-parser"
  role          = aws_iam_role.alert_lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.13"
  timeout       = 30

  filename         = data.archive_file.alert_lambda.output_path
  source_code_hash = data.archive_file.alert_lambda.output_base64sha256

  reserved_concurrent_executions = 5
  kms_key_arn                    = aws_kms_key.audit_pipeline.arn

  dead_letter_config {
    target_arn = aws_sqs_queue.alert_lambda_dlq.arn
  }
  tracing_config {
    mode = "PassThrough"
  }

  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "sqs_to_alert_lambda" {
  event_source_arn = aws_sqs_queue.audit_alert_queue.arn
  function_name    = aws_lambda_function.alert_lambda.arn
  batch_size       = 10
}

############################################
# EventBridge — nhánh CloudTrail (Filter + Transform) -> SQS
############################################

resource "aws_cloudwatch_event_rule" "cloudtrail_high_risk" {
  name = "${var.project_name}-cloudtrail-high-risk-eventbridge"

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      "$or" = [
        {
          eventSource = ["iam.amazonaws.com"]
          eventName = [
            "CreateAccessKey", "AttachUserPolicy", "AttachRolePolicy", "AttachGroupPolicy",
            "PutUserPolicy", "PutRolePolicy", "PutGroupPolicy", "CreatePolicyVersion",
            "SetDefaultPolicyVersion", "CreateLoginProfile", "UpdateLoginProfile",
          ]
        },
        {
          eventSource = ["eks.amazonaws.com"]
          eventName   = ["CreateAccessEntry", "AssociateAccessPolicy", "UpdateClusterConfig"]
        },
        {
          eventSource = ["cloudtrail.amazonaws.com"]
          eventName = [
            "StopLogging", "DeleteTrail", "UpdateTrail", "PutEventSelectors",
            "DeleteEventDataStore", "UpdateEventDataStore",
          ]
        },
      ]
    }
  })

  depends_on = [data.aws_cloudtrail.existing]
}

resource "aws_cloudwatch_event_target" "to_sqs" {
  rule      = aws_cloudwatch_event_rule.cloudtrail_high_risk.name
  target_id = "audit-alert-queue"
  arn       = aws_sqs_queue.audit_alert_queue.arn

  input_transformer {
    input_paths = {
      eventName   = "$.detail.eventName"
      eventSource = "$.detail.eventSource"
      eventTime   = "$.detail.eventTime"
      sourceIp    = "$.detail.sourceIPAddress"
      actor       = "$.detail.userIdentity.arn"
    }
    input_template = <<-EOT
      {
        "source": "cloudtrail",
        "eventName": <eventName>,
        "eventSource": <eventSource>,
        "eventTime": <eventTime>,
        "sourceIp": <sourceIp>,
        "actor": <actor>
      }
    EOT
  }
}
