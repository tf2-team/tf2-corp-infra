# Mandate 20 AWS Backup: vault (locked), service role, daily managed stores,
# and hourly EBS selection by Mandate20Backup=hourly tag.
# Designed to match live production resources for terraform import.

data "aws_caller_identity" "current" {}

locals {
  vault_name     = "${var.name}-mandate20"
  backup_role    = "${var.name}-mandate20-backup-service"
  daily_plan     = "${var.name}-mandate20-daily"
  ebs_hourly_plan = "${var.name}-mandate20-ebs-hourly"
  kms_alias      = "alias/${var.name}-backup"

  common_tags = merge(var.tags, {
    Mandate = "20"
  })

  ebs_volume_arn = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:volume/*"
}

# ──────────────────────────────────────────────
# KMS for vault recovery points
# ──────────────────────────────────────────────

resource "aws_kms_key" "backup" {
  description             = "MANDATE-20 recovery points for ${var.name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "key-default-1"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name    = "${var.name}-backup"
    Purpose = "backup-recovery"
  })
}

resource "aws_kms_alias" "backup" {
  name          = local.kms_alias
  target_key_id = aws_kms_key.backup.key_id
}

# ──────────────────────────────────────────────
# Backup vault + lock
# ──────────────────────────────────────────────

resource "aws_backup_vault" "mandate20" {
  name        = local.vault_name
  kms_key_arn = aws_kms_key.backup.arn

  tags = merge(local.common_tags, {
    Name      = local.vault_name
    Purpose   = "backup-recovery"
    Retention = "${var.daily_delete_after_days}d"
  })
}

resource "aws_backup_vault_lock_configuration" "mandate20" {
  backup_vault_name   = aws_backup_vault.mandate20.name
  min_retention_days  = var.vault_min_retention_days
  max_retention_days  = var.vault_max_retention_days
}

# ──────────────────────────────────────────────
# AWS Backup service role
# ──────────────────────────────────────────────

data "aws_iam_policy_document" "backup_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "backup_service" {
  name               = local.backup_role
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "restore" {
  role       = aws_iam_role.backup_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ──────────────────────────────────────────────
# Daily plan — RDS + DynamoDB managed stores
# ──────────────────────────────────────────────

resource "aws_backup_plan" "daily" {
  name = local.daily_plan

  rule {
    rule_name                = "daily-managed-store-snapshot"
    target_vault_name        = aws_backup_vault.mandate20.name
    schedule                 = var.daily_schedule_expression
    schedule_expression_timezone = "Etc/UTC"
    start_window             = 60
    completion_window        = 360
    enable_continuous_backup = false

    lifecycle {
      delete_after = var.daily_delete_after_days
    }
  }

  tags = local.common_tags
}

resource "aws_backup_selection" "daily_managed_stores" {
  name         = "managed-revenue-stores"
  iam_role_arn = aws_iam_role.backup_service.arn
  plan_id      = aws_backup_plan.daily.id
  resources    = var.daily_backup_resource_arns
}

# ──────────────────────────────────────────────
# Hourly plan — EBS volumes tagged Mandate20Backup=hourly
# ──────────────────────────────────────────────

resource "aws_backup_plan" "ebs_hourly" {
  name = local.ebs_hourly_plan

  rule {
    rule_name                    = "hourly-persistent-volume-snapshot"
    target_vault_name            = aws_backup_vault.mandate20.name
    schedule                     = var.ebs_hourly_schedule_expression
    schedule_expression_timezone = "Etc/UTC"
    start_window                 = 60
    completion_window            = 180
    enable_continuous_backup     = false

    lifecycle {
      delete_after = var.ebs_hourly_delete_after_days
    }
  }

  tags = local.common_tags
}

resource "aws_backup_selection" "ebs_hourly" {
  name         = "tagged-persistent-ebs-volumes"
  iam_role_arn = aws_iam_role.backup_service.arn
  plan_id      = aws_backup_plan.ebs_hourly.id
  resources    = [local.ebs_volume_arn]

  condition {
    string_equals {
      key   = "aws:ResourceTag/${var.ebs_selection_tag_key}"
      value = var.ebs_selection_tag_value
    }
  }
}

# Change trail: @hungxqt - 2026-07-22 - Import-ready Mandate 20 vault, daily and EBS hourly backup.
