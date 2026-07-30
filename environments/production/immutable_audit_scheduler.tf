locals {
  immutable_audit_scheduler_enabled    = local.immutable_audit_health_enabled || local.immutable_audit_k8s_sealer_enabled || local.immutable_audit_validation_enabled
  immutable_audit_scheduler_group_name = "${local.immutable_audit_trail_name}-schedules"
  immutable_audit_scheduler_role_name  = "${local.immutable_audit_trail_name}-scheduler-role"
}

resource "aws_scheduler_schedule_group" "immutable_audit" {
  count = local.immutable_audit_scheduler_enabled ? 1 : 0

  name = local.immutable_audit_scheduler_group_name

  tags = merge(var.tags, {
    Name    = local.immutable_audit_scheduler_group_name
    Mandate = "MD12"
    Purpose = "audit-control-schedules"
  })
}

data "aws_iam_policy_document" "immutable_audit_scheduler_assume" {
  count = local.immutable_audit_scheduler_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "immutable_audit_scheduler" {
  count = local.immutable_audit_scheduler_enabled ? 1 : 0

  name               = local.immutable_audit_scheduler_role_name
  assume_role_policy = data.aws_iam_policy_document.immutable_audit_scheduler_assume[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "immutable_audit_scheduler" {
  count = local.immutable_audit_scheduler_enabled ? 1 : 0

  statement {
    sid    = "InvokeScheduledAuditLambdas"
    effect = "Allow"

    actions = ["lambda:InvokeFunction"]
    resources = compact([
      local.immutable_audit_health_enabled ? "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.immutable_audit_health_check_name}" : "",
      local.immutable_audit_k8s_sealer_enabled ? "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.immutable_audit_k8s_sealer_name}" : "",
      local.immutable_audit_validation_enabled ? "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.immutable_audit_cloudtrail_validator_name}" : "",
      local.immutable_audit_validation_enabled ? "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.immutable_audit_k8s_manifest_validator_name}" : "",
    ])
  }

  statement {
    sid    = "SendScheduleFailuresToDlq"
    effect = "Allow"

    actions = ["sqs:SendMessage"]
    resources = compact([
      local.immutable_audit_health_enabled ? aws_sqs_queue.immutable_audit_health_lambda_dlq[0].arn : "",
      local.immutable_audit_k8s_sealer_enabled ? aws_sqs_queue.immutable_audit_k8s_sealer_dlq[0].arn : "",
      local.immutable_audit_validation_enabled ? aws_sqs_queue.immutable_audit_validation_dlq[0].arn : "",
    ])
  }
}

resource "aws_iam_role_policy" "immutable_audit_scheduler" {
  count = local.immutable_audit_scheduler_enabled ? 1 : 0

  name   = local.immutable_audit_scheduler_role_name
  role   = aws_iam_role.immutable_audit_scheduler[0].id
  policy = data.aws_iam_policy_document.immutable_audit_scheduler[0].json
}
