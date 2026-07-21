data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  immutable_audit_sensitive_coverage = yamldecode(file("${path.module}/audit_sensitive_coverage.yaml"))
  immutable_audit_s3_data_event_object_arns = toset(distinct(concat(
    tolist(var.immutable_audit_s3_data_event_object_arns),
    [
      for scope in try(local.immutable_audit_sensitive_coverage.s3_object_prefixes, []) :
      scope.cloudtrail_data_event_arn
    ]
  )))
  immutable_audit_bucket_name = (
    var.immutable_audit_bucket_name != ""
    ? var.immutable_audit_bucket_name
    : "${var.project_name}-cloudtrail-immutable-${data.aws_caller_identity.current.account_id}"
  )
  immutable_audit_trail_name = (
    var.immutable_audit_trail_name != ""
    ? var.immutable_audit_trail_name
    : "${var.project_name}-mandate12-immutable-audit"
  )
  immutable_audit_trail_arn = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.immutable_audit_trail_name}"
}

data "aws_iam_policy_document" "immutable_audit_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; service statements are constrained by SourceArn/encryption context where supported.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
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
    sid    = "AllowCloudTrailEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
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
      values   = ["arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/cloudtrail/${local.immutable_audit_trail_name}"]
    }
  }

}

resource "aws_kms_key" "immutable_audit" {
  description             = "KMS key for ${local.immutable_audit_trail_name} CloudTrail and CloudWatch Logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.immutable_audit_kms.json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-kms"
    Mandate = "MD4-MD12"
    Purpose = "immutable-cloudtrail-audit"
  })
}

resource "aws_kms_alias" "immutable_audit" {
  name          = "alias/${local.immutable_audit_trail_name}"
  target_key_id = aws_kms_key.immutable_audit.key_id
}

data "aws_iam_policy_document" "immutable_audit_sns_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; service statements are limited to SNS and CloudTrail.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
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
    sid    = "AllowSnsUseOfKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
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
    sid    = "AllowCloudTrailPublishToEncryptedSns"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "immutable_audit_sns" {
  description             = "KMS key for ${local.immutable_audit_trail_name} SNS delivery notifications"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.immutable_audit_sns_kms.json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-sns-kms"
    Mandate = "MD4-MD12"
    Purpose = "immutable-cloudtrail-audit-notifications"
  })
}

resource "aws_kms_alias" "immutable_audit_sns" {
  name          = "alias/${local.immutable_audit_trail_name}-sns"
  target_key_id = aws_kms_key.immutable_audit_sns.key_id
}

resource "aws_s3_bucket" "immutable_audit" {
  #checkov:skip=CKV_AWS_18:This bucket is the immutable CloudTrail destination; access is audited by CloudTrail, SNS notifications, CloudWatch Logs, and Object Lock evidence.
  #checkov:skip=CKV_AWS_144:Cross-region replication is intentionally omitted for the capstone budget; CloudTrail is multi-region and log integrity validation is enabled.
  #checkov:skip=CKV_AWS_145:Bucket default encryption uses SSE-S3 to avoid double-KMS delivery failures; CloudTrail log files are still encrypted by the trail-level customer-managed KMS key.
  bucket              = local.immutable_audit_bucket_name
  object_lock_enabled = true
  force_destroy       = false

  tags = merge(var.tags, {
    Name      = local.immutable_audit_bucket_name
    Mandate   = "MD4-MD12"
    Purpose   = "immutable-cloudtrail-audit"
    Retention = "${var.immutable_audit_retention_days}d"
  })
}

resource "aws_s3_bucket_public_access_block" "immutable_audit" {
  bucket                  = aws_s3_bucket.immutable_audit.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "immutable_audit" {
  bucket = aws_s3_bucket.immutable_audit.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "immutable_audit" {
  bucket = aws_s3_bucket.immutable_audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "immutable_audit" {
  bucket = aws_s3_bucket.immutable_audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "immutable_audit" {
  bucket = aws_s3_bucket.immutable_audit.id

  rule {
    id     = "retain-immutable-cloudtrail-logs"
    status = "Enabled"

    filter {
      prefix = "AWSLogs/"
    }

    noncurrent_version_expiration {
      noncurrent_days = max(var.immutable_audit_retention_days + 1, 91)
    }

  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  depends_on = [
    aws_s3_bucket_object_lock_configuration.immutable_audit,
    aws_s3_bucket_versioning.immutable_audit,
  ]
}

resource "aws_s3_bucket_object_lock_configuration" "immutable_audit" {
  bucket = aws_s3_bucket.immutable_audit.id

  rule {
    default_retention {
      mode = var.immutable_audit_retention_mode
      days = var.immutable_audit_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.immutable_audit]
}

data "aws_iam_policy_document" "immutable_audit_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.immutable_audit.arn,
      "${aws_s3_bucket.immutable_audit.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.immutable_audit.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.immutable_audit_trail_arn]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.immutable_audit.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.immutable_audit_trail_arn]
    }
  }

  statement {
    sid    = "DenyAuditLogDelete"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["${aws_s3_bucket.immutable_audit.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }

  statement {
    sid    = "DenyObjectLockBypass"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:BypassGovernanceRetention",
      "s3:PutObjectLegalHold",
      "s3:PutObjectRetention",
    ]
    resources = ["${aws_s3_bucket.immutable_audit.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
  }
}

resource "aws_s3_bucket_policy" "immutable_audit" {
  bucket = aws_s3_bucket.immutable_audit.id
  policy = data.aws_iam_policy_document.immutable_audit_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.immutable_audit]
}

resource "aws_sns_topic" "immutable_audit" {
  name              = "${local.immutable_audit_trail_name}-notifications"
  kms_master_key_id = aws_kms_key.immutable_audit_sns.arn

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-notifications"
    Mandate = "MD4-MD12"
    Purpose = "immutable-cloudtrail-audit"
  })
}

data "aws_iam_policy_document" "immutable_audit_sns" {
  statement {
    sid    = "AllowCloudTrailPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.immutable_audit.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.immutable_audit_trail_arn]
    }
  }
}

resource "aws_sns_topic_policy" "immutable_audit" {
  arn    = aws_sns_topic.immutable_audit.arn
  policy = data.aws_iam_policy_document.immutable_audit_sns.json
}

resource "aws_cloudwatch_log_group" "immutable_audit" {
  name              = "/aws/cloudtrail/${local.immutable_audit_trail_name}"
  retention_in_days = var.immutable_audit_cloudwatch_retention_days
  kms_key_id        = aws_kms_key.immutable_audit.arn

  tags = merge(var.tags, {
    Name    = "/aws/cloudtrail/${local.immutable_audit_trail_name}"
    Mandate = "MD4-MD12"
    Purpose = "immutable-cloudtrail-audit"
  })
}

data "aws_iam_policy_document" "immutable_audit_cloudtrail_assume" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "immutable_audit_cloudtrail_logs" {
  name               = "${local.immutable_audit_trail_name}-logs"
  assume_role_policy = data.aws_iam_policy_document.immutable_audit_cloudtrail_assume.json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-logs"
    Mandate = "MD4-MD12"
    Purpose = "immutable-cloudtrail-audit"
  })
}

data "aws_iam_policy_document" "immutable_audit_cloudtrail_logs" {
  statement {
    sid    = "WriteCloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.immutable_audit.arn}:*"]
  }
}

resource "aws_iam_role_policy" "immutable_audit_cloudtrail_logs" {
  name   = "${local.immutable_audit_trail_name}-logs"
  role   = aws_iam_role.immutable_audit_cloudtrail_logs.id
  policy = data.aws_iam_policy_document.immutable_audit_cloudtrail_logs.json
}

resource "aws_cloudtrail" "immutable_audit" {
  name                          = local.immutable_audit_trail_name
  s3_bucket_name                = aws_s3_bucket.immutable_audit.id
  kms_key_id                    = aws_kms_key.immutable_audit.arn
  sns_topic_name                = aws_sns_topic.immutable_audit.name
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.immutable_audit.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.immutable_audit_cloudtrail_logs.arn
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  enable_logging                = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    dynamic "data_resource" {
      for_each = local.immutable_audit_s3_data_event_object_arns

      content {
        type   = "AWS::S3::Object"
        values = [data_resource.value]
      }
    }
  }

  tags = merge(var.tags, {
    Name    = local.immutable_audit_trail_name
    Mandate = "MD4-MD12"
    Purpose = "immutable-cloudtrail-audit"
  })

  depends_on = [
    aws_kms_key.immutable_audit,
    aws_kms_key.immutable_audit_sns,
    aws_iam_role_policy.immutable_audit_cloudtrail_logs,
    aws_s3_bucket_object_lock_configuration.immutable_audit,
    aws_s3_bucket_policy.immutable_audit,
    aws_s3_bucket_server_side_encryption_configuration.immutable_audit,
    aws_sns_topic_policy.immutable_audit,
  ]
}

data "aws_iam_policy_document" "immutable_audit_alert_sns_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policies are scoped by the attached key; the root statement follows AWS KMS guidance so IAM can administer the key.
  #checkov:skip=CKV_AWS_111:KMS key policies require Resource "*" because the policy is attached directly to one key; service statements are limited to SNS and EventBridge.
  #checkov:skip=CKV_AWS_356:KMS key policies require Resource "*" because the key policy itself is the resource boundary.
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
    sid    = "AllowSnsUseOfKey"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
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
    sid    = "AllowEventBridgePublishToEncryptedSns"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "immutable_audit_alert_sns" {
  description             = "KMS key for ${local.immutable_audit_trail_name} tamper alert SNS topic"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.immutable_audit_alert_sns_kms.json

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-tamper-alerts-kms"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-email-alerts"
  })
}

resource "aws_kms_alias" "immutable_audit_alert_sns" {
  name          = "alias/${local.immutable_audit_trail_name}-tamper-alerts"
  target_key_id = aws_kms_key.immutable_audit_alert_sns.key_id
}

resource "aws_sns_topic" "immutable_audit_tamper_alerts" {
  name              = "${local.immutable_audit_trail_name}-tamper-alerts"
  kms_master_key_id = aws_kms_key.immutable_audit_alert_sns.arn

  tags = merge(var.tags, {
    Name    = "${local.immutable_audit_trail_name}-tamper-alerts"
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-email-alerts"
  })
}

resource "aws_sns_topic_subscription" "immutable_audit_tamper_email" {
  for_each = var.immutable_audit_alert_email_endpoints

  topic_arn = aws_sns_topic.immutable_audit_tamper_alerts.arn
  protocol  = "email-json"
  endpoint  = each.value
}

locals {
  immutable_audit_email_tamper_rule_keys = toset(["trail", "bucket", "kms"])
  immutable_audit_tamper_rule_names = [
    "${local.immutable_audit_trail_name}-trail-tamper",
    "${local.immutable_audit_trail_name}-bucket-tamper",
    "${local.immutable_audit_trail_name}-kms-tamper",
    "${local.immutable_audit_trail_name}-eb-rule-tamper",
    "${local.immutable_audit_trail_name}-eb-target-tamper",
    "${local.immutable_audit_trail_name}-eb-deny-tamper",
    "${local.immutable_audit_trail_name}-sns-topic-tamper",
    "${local.immutable_audit_trail_name}-sns-sub-tamper",
    "${local.immutable_audit_trail_name}-lambda-tamper",
    "${local.immutable_audit_trail_name}-sqs-tamper",
    "${local.immutable_audit_trail_name}-secrets-tamper",
  ]
  immutable_audit_tamper_rule_arn_prefix = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:rule/${local.immutable_audit_trail_name}-"
  immutable_audit_lambda_function_names = concat(
    local.immutable_audit_discord_enabled ? ["${local.immutable_audit_trail_name}-discord-forwarder"] : [],
    local.immutable_audit_health_enabled ? ["${local.immutable_audit_trail_name}-health-check"] : []
  )
  immutable_audit_sqs_queue_urls = concat(
    local.immutable_audit_discord_enabled ? [
      aws_sqs_queue.immutable_audit_discord[0].url,
      aws_sqs_queue.immutable_audit_discord_dlq[0].url,
      aws_sqs_queue.immutable_audit_discord_lambda_dlq[0].url,
    ] : [],
    local.immutable_audit_health_enabled ? [aws_sqs_queue.immutable_audit_health_lambda_dlq[0].url] : []
  )
  immutable_audit_secret_ids = (
    local.immutable_audit_discord_enabled
    ? [
      local.immutable_audit_discord_webhook_secret_arn,
      "${local.immutable_audit_trail_name}-discord-webhook",
    ]
    : []
  )

  immutable_audit_tamper_event_rules = {
    trail = {
      name        = "${local.immutable_audit_trail_name}-trail-tamper"
      description = "Alert when CloudTrail logging path is stopped, deleted, or reconfigured."
      pattern = {
        source      = ["aws.cloudtrail"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["cloudtrail.amazonaws.com"]
          eventName = [
            "StopLogging",
            "DeleteTrail",
            "UpdateTrail",
            "PutEventSelectors",
          ]
        }
      }
    }
    bucket = {
      name        = "${local.immutable_audit_trail_name}-bucket-tamper"
      description = "Alert when the immutable CloudTrail log bucket policy, lifecycle, versioning, or Object Lock configuration changes."
      pattern = {
        source      = ["aws.s3"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["s3.amazonaws.com"]
          eventName = [
            "PutBucketPolicy",
            "DeleteBucketPolicy",
            "PutLifecycleConfiguration",
            "DeleteBucketLifecycle",
            "PutBucketVersioning",
            "PutBucketObjectLockConfiguration",
          ]
          requestParameters = {
            bucketName = [aws_s3_bucket.immutable_audit.bucket]
          }
        }
      }
    }
    kms = {
      name        = "${local.immutable_audit_trail_name}-kms-tamper"
      description = "Alert when KMS keys protecting immutable audit evidence are disabled, deleted, or have key policy changed."
      pattern = {
        source      = ["aws.kms"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["kms.amazonaws.com"]
          eventName = [
            "PutKeyPolicy",
            "DisableKey",
            "ScheduleKeyDeletion",
          ]
          requestParameters = {
            keyId = concat([
              aws_kms_key.immutable_audit.key_id,
              aws_kms_key.immutable_audit.arn,
              aws_kms_key.immutable_audit_sns.key_id,
              aws_kms_key.immutable_audit_sns.arn,
              aws_kms_key.immutable_audit_alert_sns.key_id,
              aws_kms_key.immutable_audit_alert_sns.arn,
              ], local.immutable_audit_discord_enabled || local.immutable_audit_health_enabled ? [
              aws_kms_key.immutable_audit_alert_runtime[0].key_id,
              aws_kms_key.immutable_audit_alert_runtime[0].arn,
            ] : [])
          }
        }
      }
    }
    eventbridge_denied = {
      name        = "${local.immutable_audit_trail_name}-eb-deny-tamper"
      description = "Alert when SCP denies attempts to disable or delete audit EventBridge rules."
      pattern = {
        source      = ["aws.events"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["events.amazonaws.com"]
          eventName = [
            "DeleteRule",
            "DisableRule",
          ]
          errorMessage = [{
            wildcard = "*${local.immutable_audit_tamper_rule_arn_prefix}*"
          }]
        }
      }
    }
    eventbridge_target = {
      name        = "${local.immutable_audit_trail_name}-eb-target-tamper"
      description = "Alert when audit EventBridge rule targets are changed or removed."
      pattern = {
        source      = ["aws.events"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["events.amazonaws.com"]
          eventName = [
            "PutTargets",
            "RemoveTargets",
          ]
          requestParameters = {
            rule = local.immutable_audit_tamper_rule_names
          }
        }
      }
    }
    eventbridge_rule = {
      name        = "${local.immutable_audit_trail_name}-eb-rule-tamper"
      description = "Alert when audit EventBridge rules are changed, disabled, or deleted."
      pattern = {
        source      = ["aws.events"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["events.amazonaws.com"]
          eventName = [
            "DeleteRule",
            "DisableRule",
            "PutRule",
          ]
          requestParameters = {
            name = local.immutable_audit_tamper_rule_names
          }
        }
      }
    }
    sns = {
      name        = "${local.immutable_audit_trail_name}-sns-topic-tamper"
      description = "Alert when SNS topics used by audit alerts are changed or removed."
      pattern = {
        source      = ["aws.sns"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["sns.amazonaws.com"]
          eventName = [
            "DeleteTopic",
            "SetTopicAttributes",
            "Subscribe",
            "Unsubscribe",
          ]
          requestParameters = {
            topicArn = [aws_sns_topic.immutable_audit_tamper_alerts.arn]
          }
        }
      }
    }
    sns_subscription = {
      name        = "${local.immutable_audit_trail_name}-sns-sub-tamper"
      description = "Alert when SNS subscriptions used by audit alerts are changed or removed."
      pattern = {
        source      = ["aws.sns"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["sns.amazonaws.com"]
          eventName = [
            "Unsubscribe",
          ]
          requestParameters = {
            subscriptionArn = [{
              prefix = "${aws_sns_topic.immutable_audit_tamper_alerts.arn}:"
            }]
          }
        }
      }
    }
    lambda = {
      name        = "${local.immutable_audit_trail_name}-lambda-tamper"
      description = "Alert when Lambda functions or event source mappings used by audit alerts are changed."
      pattern = {
        source      = ["aws.lambda"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["lambda.amazonaws.com"]
          eventName = [
            "DeleteEventSourceMapping",
            "DeleteFunction",
            "PutFunctionConcurrency",
            "UpdateEventSourceMapping",
            "UpdateFunctionCode",
            "UpdateFunctionConfiguration",
          ]
          requestParameters = {
            functionName = local.immutable_audit_lambda_function_names
          }
        }
      }
    }
    sqs = {
      name        = "${local.immutable_audit_trail_name}-sqs-tamper"
      description = "Alert when SQS queues used by Discord audit alert delivery are deleted, purged, or reconfigured."
      pattern = {
        source      = ["aws.sqs"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["sqs.amazonaws.com"]
          eventName = [
            "DeleteQueue",
            "PurgeQueue",
            "SetQueueAttributes",
          ]
          requestParameters = {
            queueUrl = local.immutable_audit_sqs_queue_urls
          }
        }
      }
    }
    secrets = {
      name        = "${local.immutable_audit_trail_name}-secrets-tamper"
      description = "Alert when Secrets Manager secrets used by audit alert delivery are changed or deleted."
      pattern = {
        source      = ["aws.secretsmanager"]
        detail-type = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["secretsmanager.amazonaws.com"]
          eventName = [
            "DeleteSecret",
            "PutSecretValue",
            "UpdateSecret",
          ]
          requestParameters = {
            secretId = local.immutable_audit_secret_ids
          }
        }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "immutable_audit_tamper" {
  for_each = local.immutable_audit_tamper_event_rules

  name          = each.value.name
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
  state         = "ENABLED"

  tags = merge(var.tags, {
    Name    = each.value.name
    Mandate = "MD12"
    Purpose = "audit-anti-defeat-alert"
  })
}

resource "aws_cloudwatch_event_target" "immutable_audit_tamper" {
  for_each = {
    for key, rule in aws_cloudwatch_event_rule.immutable_audit_tamper : key => rule
    if contains(local.immutable_audit_email_tamper_rule_keys, key)
  }

  rule      = each.value.name
  target_id = "email-audit-alert"
  arn       = aws_sns_topic.immutable_audit_tamper_alerts.arn
}

module "ecr" {
  source = "../../modules/ecr"

  # Creates techx-corp/<service> for every platform bake service (module default catalog)
  project_name           = var.ecr_project_name
  naming_mode            = var.ecr_naming_mode
  image_tag_mutability   = var.ecr_image_tag_mutability
  keep_last_n_images     = var.ecr_keep_last_n_images
  keep_last_n_buildcache = var.ecr_keep_last_n_buildcache
  scan_on_push           = var.ecr_scan_on_push
  force_delete           = var.ecr_force_delete
  repositories           = var.ecr_repository_overrides
}

module "vpc" {
  source = "../../modules/vpc"

  name             = "${var.project_name}-vpc"
  cidr_block       = var.vpc_cidr_block
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  nat_gateways     = var.nat_gateways
  eks_cluster_name = var.cluster_name
}

# Resolve subnet_keys → subnet IDs from VPC (one NG per AZ for balanced placement).
locals {
  node_groups = {
    for name, ng in var.node_groups : name => {
      instance_types = ng.instance_types
      capacity_type  = ng.capacity_type
      ami_type       = ng.ami_type
      disk_size      = ng.disk_size
      desired_size   = ng.desired_size
      min_size       = ng.min_size
      max_size       = ng.max_size
      labels         = ng.labels
      taints         = ng.taints
      max_pods       = ng.max_pods
      subnet_ids = (
        ng.subnet_ids != null
        ? ng.subnet_ids
        : (
          ng.subnet_keys != null
          ? [for k in ng.subnet_keys : module.vpc.private_subnet_ids[k]]
          : null
        )
      )
    }
  }
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  subnet_ids         = module.vpc.private_subnet_ids_list

  enabled_cluster_log_types  = var.enabled_cluster_log_types
  cluster_log_retention_days = var.cluster_log_retention_days

  node_groups = local.node_groups
  addons      = var.addons

  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn
  plan_role_arn              = var.plan_role_arn
  access_entries             = var.access_entries

  # Tag MNG ASGs for CA auto-discovery when Cluster Autoscaler is enabled (IAM-only is enough).
  enable_cluster_autoscaler_asg_tags = var.cluster_autoscaler_enabled
}

# GitOps control plane (REL-09). Same enablement model as development (API access required at apply).
# UI: https://internal.hungtran.id.vn/argocd via frontend-proxy Envoy (VPN + private DNS).
# CloudFront must block /argocd (cloudfront_blocked_prefixes).
module "argocd" {
  source = "../../modules/argocd"

  enabled         = var.argocd_enabled
  chart_version   = var.argocd_chart_version
  server_rootpath = var.argocd_server_rootpath
  server_insecure = var.argocd_server_insecure
  server_domain   = var.private_dns_enabled ? var.private_dns_zone_name : "argocd.local"
  server_url = (
    var.argocd_server_url != ""
    ? var.argocd_server_url
    : (
      var.private_dns_enabled && var.argocd_server_rootpath != ""
      ? "https://${var.private_dns_zone_name}${var.argocd_server_rootpath}"
      : ""
    )
  )
}

# ──────────────────────────────────────────────
# SEC-05: AWS Secrets Manager (metadata) + ESO IRSA
# ──────────────────────────────────────────────

module "secrets_manager" {
  source = "../../modules/secrets-manager"

  name_prefix             = var.secrets_manager_name_prefix
  recovery_window_in_days = var.secrets_manager_recovery_window_in_days
  kms_key_id              = var.secrets_manager_kms_key_id
  tags                    = var.tags
}

module "mem0_postgresql" {
  source = "../../modules/mem0-postgresql"

  name                                = var.project_name
  vpc_id                              = module.vpc.vpc_id
  subnet_ids                          = module.vpc.private_subnet_ids_list
  eks_client_security_group_id        = module.eks.cluster_security_group_id
  engine_version                      = var.mem0_postgresql_engine_version
  instance_class                      = var.mem0_postgresql_instance_class
  allocated_storage                   = var.mem0_postgresql_allocated_storage
  max_allocated_storage               = var.mem0_postgresql_max_allocated_storage
  multi_az                            = var.mem0_postgresql_multi_az
  iam_database_authentication_enabled = var.mem0_postgresql_iam_database_authentication_enabled
  backup_retention_period             = var.mem0_postgresql_backup_retention_period
  deletion_protection                 = var.mem0_postgresql_deletion_protection
  skip_final_snapshot                 = var.mem0_postgresql_skip_final_snapshot
  performance_insights_enabled        = var.mem0_postgresql_performance_insights_enabled
  kms_key_id                          = var.mem0_postgresql_kms_key_id
  tags                                = var.tags
}

module "external_secrets" {
  source = "../../modules/external-secrets"

  enabled           = var.external_secrets_enabled
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer
  secret_arns = concat(
    module.secrets_manager.secret_arns_list,
    [
      module.commerce_ha.valkey_auth_secret_arn,
      module.msk.msk_bootstrap_secret_arn,
      module.msk.scram_secret_arn,
      module.rds_postgresql.connection_secret_arn,
      module.mem0_postgresql.master_user_secret_arn,
    ],
  )
  kms_key_arns = [
    module.commerce_ha.commerce_kms_key_arn,
    module.msk.msk_kms_key_arn,
    module.rds_postgresql.kms_key_arn,
  ]
  aws_region                  = var.aws_region
  install_helm                = var.external_secrets_install_helm
  create_cluster_secret_store = var.external_secrets_create_cluster_secret_store
  chart_version               = var.external_secrets_chart_version
  tags                        = var.tags
}

module "ai_model_storage" {
  source = "../../modules/ai-model-storage"

  name                    = var.project_name
  aws_region              = var.aws_region
  vpc_id                  = module.vpc.vpc_id
  private_route_table_ids = module.vpc.private_route_table_ids
  oidc_provider_arn       = module.eks.oidc_provider_arn
  oidc_issuer_url         = module.eks.oidc_issuer
  consumers = {
    product-reviews = {
      namespace            = "techx-corp-prod"
      service_account_name = "product-reviews"
      model_prefix         = "protectai/deberta-v3-base-prompt-injection-v2/"
      allow_list_bucket    = true
    }
    shopping-copilot = {
      namespace                     = "techx-corp-prod"
      service_account_name          = "shopping-copilot"
      model_prefix                  = "protectai/deberta-v3-base-prompt-injection-v2/"
      allow_list_bucket             = true
      bedrock_inference_profile_ids = ["global.amazon.nova-2-lite-v1:0"]
    }
    mem0 = {
      namespace            = "techx-corp-prod"
      service_account_name = "mem0"
      model_prefix         = "fastembed/paraphrase-multilingual-MiniLM-L12-v2/"
    }
  }
  database_iam_auth = {
    mem0 = {
      db_resource_id = module.mem0_postgresql.resource_id
      database_user  = var.mem0_postgresql_iam_database_user
    }
  }
  tags = var.tags
}

# DIRECTIVE #3: remove stateful single points of failure from the customer
# money path. Cart uses managed Multi-AZ Valkey; checkout persists Kafka events
# to a DynamoDB outbox through a least-privilege IRSA role.
module "commerce_ha" {
  source = "../../modules/commerce-ha"

  name                            = var.project_name
  vpc_id                          = module.vpc.vpc_id
  private_subnet_ids              = module.vpc.private_subnet_ids_list
  eks_client_security_group_id    = module.eks.cluster_security_group_id
  oidc_provider_arn               = module.eks.oidc_provider_arn
  oidc_issuer_url                 = module.eks.oidc_issuer
  checkout_namespace              = "techx-corp-prod"
  checkout_service_account        = "checkout"
  valkey_node_type                = var.commerce_valkey_node_type
  valkey_engine_version           = var.commerce_valkey_engine_version
  private_dns_zone                = var.commerce_private_dns_zone
  valkey_snapshot_retention_limit = var.commerce_valkey_snapshot_retention_limit
  tags                            = var.tags
}

# MANDATE-20: managed policy that denies deleting backups / disabling DynamoDB PITR.
# Policy is always created; attach to operator role names via var.backup_protection_attach_role_names.
module "backup_protection" {
  source = "../../modules/backup-protection"

  name              = var.project_name
  attach_role_names = var.backup_protection_attach_role_names
  tags              = var.tags
}

# DIRECTIVE #8: managed PostgreSQL replaces the in-cluster StatefulSet. RDS
# owns the master password; application users are loaded during migration.
module "rds_postgresql" {
  source = "../../modules/rds-postgresql"

  name                         = var.project_name
  vpc_id                       = module.vpc.vpc_id
  subnet_ids                   = [module.vpc.private_subnet_ids["priv-1a-nodes"], module.vpc.private_subnet_ids["priv-1b-nodes"]]
  eks_client_security_group_id = module.eks.cluster_security_group_id
  engine_version               = var.rds_postgresql_engine_version
  instance_class               = var.rds_postgresql_instance_class
  database_name                = var.rds_postgresql_database_name
  allocated_storage            = var.rds_postgresql_allocated_storage
  max_allocated_storage        = var.rds_postgresql_max_allocated_storage
  multi_az                     = var.rds_postgresql_multi_az
  backup_retention_period      = var.rds_postgresql_backup_retention_days
  tags                         = var.tags
}

# DIRECTIVE #8: Amazon MSK cluster replacement for in-cluster Kafka broker
module "msk" {
  source = "../../modules/msk"

  name                         = var.project_name
  vpc_id                       = module.vpc.vpc_id
  subnet_ids                   = [module.vpc.private_subnet_ids["priv-1a-nodes"], module.vpc.private_subnet_ids["priv-1b-nodes"]]
  eks_client_security_group_id = module.eks.cluster_security_group_id
  kafka_version                = var.msk_kafka_version
  broker_instance_type         = var.msk_broker_instance_type
  ebs_volume_size              = var.msk_ebs_volume_size
  vpc_cidr_block               = module.vpc.vpc_cidr_block
  tags                         = var.tags
}

# ──────────────────────────────────────────────
# Karpenter — node autoscaling (Spot-preferred; same model as development)
# ──────────────────────────────────────────────

module "karpenter" {
  source = "../../modules/karpenter"

  enabled                  = var.karpenter_enabled
  cluster_name             = module.eks.cluster_name
  cluster_endpoint         = module.eks.cluster_endpoint
  oidc_provider_arn        = module.eks.oidc_provider_arn
  oidc_issuer_url          = module.eks.oidc_issuer
  aws_region               = var.aws_region
  discovery_tag_value      = module.eks.cluster_name
  install_helm             = var.karpenter_install_helm
  create_node_resources    = var.karpenter_create_node_resources
  chart_version            = var.karpenter_chart_version
  spot_preferred           = var.karpenter_spot_preferred
  ami_alias                = var.karpenter_ami_alias
  instance_categories      = var.karpenter_instance_categories
  expire_after             = var.karpenter_expire_after
  termination_grace_period = var.karpenter_termination_grace_period
  node_taints              = var.karpenter_node_taints
  nodepool_weights         = var.karpenter_nodepool_weights
  disruption_budget_nodes  = var.karpenter_disruption_budget_nodes
  consolidate_after        = var.karpenter_consolidate_after
  feature_gates            = var.karpenter_feature_gates
  nodepool_cpu_limit       = var.karpenter_nodepool_cpu_limit
  nodepool_memory_limit    = var.karpenter_nodepool_memory_limit
  availability_zones       = var.karpenter_availability_zones
  node_max_pods            = var.karpenter_node_max_pods
  min_instance_cpu         = var.karpenter_min_instance_cpu
  tags                     = var.tags
}

# ──────────────────────────────────────────────
# Cluster Autoscaler — hybrid: system-* MNG ASGs only
# Karpenter remains the elastic autoscaler for spot-tolerant app nodes.
# CA discovery tags apply only to system-* groups (modules/eks).
# ──────────────────────────────────────────────

module "cluster_autoscaler" {
  source = "../../modules/cluster-autoscaler"

  enabled           = var.cluster_autoscaler_enabled
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer
  aws_region        = var.aws_region
  install_helm      = var.cluster_autoscaler_install_helm
  chart_version     = var.cluster_autoscaler_chart_version
  tags              = var.tags
}

# ──────────────────────────────────────────────
# CloudFront edge → internal storefront ALB (VPC origin)
# Path blocking lives here (not on the ALB). See docs/cloudfront.md
# ──────────────────────────────────────────────

module "cloudfront_storefront" {
  source = "../../modules/cloudfront-alb"

  enabled               = var.cloudfront_enabled
  acm_certificate_arn   = var.cloudfront_acm_certificate_arn
  origin_domain_name    = var.cloudfront_origin_domain_name
  origin_alb_arn        = var.cloudfront_origin_alb_arn
  aliases               = var.cloudfront_aliases
  comment               = "${var.project_name} storefront"
  price_class           = var.cloudfront_price_class
  block_sensitive_paths = var.cloudfront_block_sensitive_paths
  blocked_prefixes      = var.cloudfront_blocked_prefixes
  block_function_name   = "${var.project_name}-block-sensitive-paths"
  vpc_origin_name       = "${var.project_name}-storefront-alb"
  web_acl_id            = var.cloudfront_web_acl_id
  tags                  = var.tags
}

# ──────────────────────────────────────────────
# Client VPN — private operator access to internal storefront ALB + EKS API
# Bypass CloudFront path blocks for /grafana, /jaeger, …
# Opens cluster SG TCP 443 from VPN client CIDR (private API while on VPN).
# Public EKS endpoint remains as configured on the cluster (dual access).
# See docs/client-vpn.md
# ──────────────────────────────────────────────

module "client_vpn" {
  source = "../../modules/client-vpn"

  enabled                           = var.client_vpn_enabled
  name                              = "${var.project_name}-client-vpn"
  vpc_id                            = module.vpc.vpc_id
  vpc_cidr_block                    = module.vpc.vpc_cidr_block
  subnet_ids                        = length(var.client_vpn_subnet_ids) > 0 ? var.client_vpn_subnet_ids : [module.vpc.private_subnet_ids_list[0]]
  client_cidr_block                 = var.client_vpn_client_cidr_block
  server_certificate_arn            = var.client_vpn_server_certificate_arn
  client_root_certificate_chain_arn = var.client_vpn_client_ca_arn
  split_tunnel                      = var.client_vpn_split_tunnel
  alb_security_group_ids            = var.client_vpn_alb_security_group_ids
  # Private Kubernetes API path for VPN clients (public endpoint unchanged).
  eks_cluster_security_group_ids = [module.eks.cluster_security_group_id]
  tags                           = var.tags
}

# ──────────────────────────────────────────────
# Private DNS — internal.<domain> → ALB; services via path (/grafana, /jaeger, …)
# See docs/client-vpn.md
# ──────────────────────────────────────────────

module "private_dns" {
  source = "../../modules/private-dns"

  enabled             = var.private_dns_enabled
  zone_name           = var.private_dns_zone_name
  vpc_id              = module.vpc.vpc_id
  alb_arn             = var.cloudfront_origin_alb_arn
  service_paths       = var.private_dns_service_paths
  acm_certificate_arn = var.private_dns_acm_certificate_arn
  use_https_urls      = var.private_dns_use_https_urls
  tags                = var.tags
}

# ──────────────────────────────────────────────
# Cost budgets — onboarding ~$300/week × ~3 weeks → monthly $900
# AWS Budgets has no WEEKLY time_unit (only DAILY/MONTHLY/…).
# SNS protocol email-json; confirm subscription after apply.
# Account-level; production only (do not duplicate in development).
# ──────────────────────────────────────────────

module "cost_budgets" {
  source = "../../modules/cost-budgets"

  enabled                                    = var.cost_budgets_enabled
  name_prefix                                = var.project_name
  alert_email                                = var.cost_budgets_alert_email
  monthly_limit_usd                          = var.cost_budgets_monthly_limit_usd
  daily_limit_usd                            = var.cost_budgets_daily_limit_usd
  create_daily_budget                        = var.cost_budgets_create_daily
  budget_actions_enabled                     = var.cost_budget_actions_enabled
  budget_action_iam_target_role_names        = var.cost_budget_actions_enabled && module.karpenter.controller_role_name != null ? [module.karpenter.controller_role_name] : []
  budget_action_monthly_threshold_percentage = var.cost_budget_action_monthly_threshold_percentage
  budget_action_daily_threshold_percentage   = var.cost_budget_action_daily_threshold_percentage
  budget_action_daily_enabled                = var.cost_budget_daily_action_enabled
  tags                                       = var.tags
}

# ──────────────────────────────────────────────
# Cost Anomaly Detection — spike vs baseline (per SERVICE)
# Complements budgets (ceiling). Account-level; production only.
# ──────────────────────────────────────────────

module "cost_anomaly" {
  source = "../../modules/cost-anomaly"

  enabled             = var.cost_anomaly_enabled
  name_prefix         = var.project_name
  alert_email         = var.cost_anomaly_alert_email
  frequency           = var.cost_anomaly_frequency
  impact_absolute_usd = var.cost_anomaly_impact_absolute_usd
  impact_percentage   = var.cost_anomaly_impact_percentage
  tags                = var.tags
}

# ──────────────────────────────────────────────
# P3: CUR 2.0 Data Export → Athena + Grafana IRSA
# Existing export discovered via BCM Data Exports: finops-watch-cur.
# Terraform does not recreate the CUR export; it catalogs and guards queries.
# ──────────────────────────────────────────────

module "cur_athena" {
  source = "../../modules/cur-athena"

  providers = {
    aws = aws.cur
  }

  enabled                      = var.cur_athena_enabled
  name_prefix                  = var.project_name
  cur_bucket_name              = var.cur_athena_cur_bucket_name
  cur_s3_prefix                = var.cur_athena_cur_s3_prefix
  cur_export_name              = var.cur_athena_cur_export_name
  database_name                = var.cur_athena_database_name
  crawler_name                 = var.cur_athena_crawler_name
  athena_workgroup_name        = var.cur_athena_workgroup_name
  athena_results_bucket_name   = var.cur_athena_results_bucket_name
  athena_bytes_cutoff          = var.cur_athena_bytes_cutoff
  oidc_provider_arn            = module.eks.oidc_provider_arn
  oidc_issuer_url              = module.eks.oidc_issuer
  grafana_namespace            = var.cur_athena_grafana_namespace
  grafana_service_account_name = var.cur_athena_grafana_service_account_name
  tags                         = var.tags
}

# ──────────────────────────────────────────────
# Overlay: Cost Anomaly Routing via AWS User Notifications (email first)
# ──────────────────────────────────────────────

module "cost_anomaly_routing" {
  source = "../../modules/cost-anomaly-routing"

  enabled                 = var.cost_anomaly_routing_enabled
  name_prefix             = var.project_name
  notification_email      = var.cost_anomaly_routing_email
  notification_regions    = var.cost_anomaly_routing_regions
  notification_hub_region = var.cost_anomaly_routing_hub_region
  impact_absolute_usd     = var.cost_anomaly_routing_impact_absolute_usd
  aggregation_duration    = var.cost_anomaly_routing_aggregation_duration
  tags                    = var.tags
}

# ──────────────────────────────────────────────
# Mandate 05 runtime security alerting — admission deny classifier
# No GuardDuty runtime agent is enabled here; GuardDuty/node-role routing stay
# feature-flagged until cost and baseline are approved.
# ──────────────────────────────────────────────

module "runtime_security_alerting" {
  source = "../../modules/runtime-security-alerting"

  enabled              = var.runtime_security_alerting_enabled
  name_prefix          = var.project_name
  cluster_name         = module.eks.cluster_name
  audit_log_group_name = var.runtime_security_audit_log_group_name != "" ? var.runtime_security_audit_log_group_name : "/aws/eks/${module.eks.cluster_name}/cluster"
  alert_email          = var.runtime_security_alert_email
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids_list

  enable_guardduty_eventbridge    = var.runtime_security_enable_guardduty_eventbridge
  enable_node_role_anomaly_events = var.runtime_security_enable_node_role_anomaly_events
  node_role_arns = toset([
    for arn in [
      module.eks.node_role_arn,
      module.karpenter.node_role_arn,
    ] : arn
    if arn != null && arn != ""
  ])

  tags = var.tags
}

# ──────────────────────────────────────────────
# Overlay: Cost Optimization Hub + Data Export backlog
# ──────────────────────────────────────────────

# ------------------------------------------------------------------------------
# Mandate 11.2 audit detection pipeline
# Coarse filters only: CloudTrail/EventBridge and EKS audit logs are forwarded as
# raw events to the Task 11.3 parser Lambda. Keep disabled until the 11.3 parser
# package and end-to-end test window are ready.
# ------------------------------------------------------------------------------

module "audit_detection_pipeline" {
  source = "../../modules/audit-detection-pipeline"

  enabled                               = var.audit_detection_pipeline_enabled
  name_prefix                           = var.project_name
  cluster_name                          = module.eks.cluster_name
  audit_log_group_name                  = var.audit_detection_audit_log_group_name != "" ? var.audit_detection_audit_log_group_name : "/aws/eks/${module.eks.cluster_name}/cluster"
  lambda_function_name                  = var.audit_detection_lambda_function_name
  lambda_role_name                      = var.audit_detection_lambda_role_name
  lambda_policy_name                    = var.audit_detection_lambda_policy_name
  dlq_name                              = var.audit_detection_dlq_name
  lambda_kms_key_arn                    = var.audit_detection_lambda_kms_key_arn
  lambda_tracing_mode                   = var.audit_detection_lambda_tracing_mode
  cloudtrail_event_rule_name            = var.audit_detection_cloudtrail_event_rule_name
  cloudtrail_event_target_id            = var.audit_detection_cloudtrail_event_target_id
  eks_audit_subscription_filter_name    = var.audit_detection_eks_audit_subscription_filter_name
  eks_audit_filter_pattern              = var.audit_detection_eks_audit_filter_pattern
  lambda_reserved_concurrent_executions = var.audit_detection_lambda_reserved_concurrent_executions
  alarm_action_arns                     = var.audit_detection_alarm_action_arns
  enable_discord_router                 = var.audit_detection_enable_discord_router
  alert_ready_queue_name                = var.audit_detection_alert_ready_queue_name
  alert_ready_dlq_name                  = var.audit_detection_alert_ready_dlq_name
  router_lambda_function_name           = var.audit_detection_router_lambda_function_name
  router_lambda_role_name               = var.audit_detection_router_lambda_role_name
  router_lambda_policy_name             = var.audit_detection_router_lambda_policy_name
  discord_webhook_secret_name           = var.audit_detection_discord_webhook_secret_name
  discord_webhook_secret_arn            = var.audit_detection_discord_webhook_secret_arn
  ttd_threshold_seconds                 = var.audit_detection_ttd_threshold_seconds
  ttd_dashboard_name                    = var.audit_detection_ttd_dashboard_name
  tags                                  = var.tags
}

module "cost_optimization_backlog" {
  source = "../../modules/cost-optimization-backlog"

  enabled                     = var.cost_optimization_backlog_enabled
  name_prefix                 = var.project_name
  bucket_name                 = var.cost_optimization_backlog_bucket_name
  s3_prefix                   = var.cost_optimization_backlog_s3_prefix
  export_name                 = var.cost_optimization_backlog_export_name
  create_export               = var.cost_optimization_backlog_create_export
  database_name               = var.cost_optimization_backlog_database_name
  crawler_name                = var.cost_optimization_backlog_crawler_name
  athena_workgroup_name       = var.cost_optimization_backlog_workgroup_name
  athena_bytes_cutoff         = var.cost_optimization_backlog_athena_bytes_cutoff
  include_member_accounts     = var.cost_optimization_backlog_include_member_accounts
  manage_enrollment           = var.cost_optimization_backlog_manage_enrollment
  include_all_recommendations = var.cost_optimization_backlog_include_all_recommendations
  tags                        = var.tags
}
# ──────────────────────────────────────────────
# Mandate 10: Sigstore policy-controller IRSA Role
# ──────────────────────────────────────────────


data "aws_iam_policy_document" "policy_controller_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:cosign-system:policy-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_issuer, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "policy_controller" {
  name               = "${var.project_name}-policy-controller"
  assume_role_policy = data.aws_iam_policy_document.policy_controller_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "policy_controller" {
  statement {
    sid    = "EcrRead"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages"
    ]
    resources = [
      "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/techx-corp/*"
    ]
  }

  statement {
    sid    = "KmsRead"
    effect = "Allow"
    actions = [
      "kms:GetPublicKey",
      "kms:DescribeKey"
    ]
    resources = [
      "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alias/tf2-cosign-signing-key",
      "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*"
    ]
  }
}

resource "aws_iam_role_policy" "policy_controller" {
  name   = "${var.project_name}-policy-controller"
  role   = aws_iam_role.policy_controller.id
  policy = data.aws_iam_policy_document.policy_controller.json
}

# Change trail: @hungxqt - 2026-07-19 - Hybrid CA on system MNG; remove dual-autoscaler mutual exclusion.
# Change trail: @hungxqt - 2026-07-20 - Enable EKS control plane CloudWatch logs with retention.
# Change trail: @hungxqt - 2026-07-20 - Wire MANDATE-20 backup_protection module and Valkey snapshot retention.
