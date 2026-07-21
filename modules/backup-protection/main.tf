# Managed IAM policy: deny destructive backup/PITR actions for day-to-day operators.
# Attach to operator / PowerUser-style roles. Break-glass admin roles stay unattached.

data "aws_iam_policy_document" "deny_destructive_backup" {
  #checkov:skip=CKV_AWS_356:Deny-statements intentionally use Resource "*" so any backup/snapshot ARN is covered; effect is Deny only.

  statement {
    sid    = "DenyDestructiveRdsBackupActions"
    effect = "Deny"
    actions = [
      "rds:DeleteDBSnapshot",
      "rds:DeleteDBClusterSnapshot",
      "rds:DeleteDBInstanceAutomatedBackup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyDestructiveDynamoDbBackupActions"
    effect = "Deny"
    actions = [
      "dynamodb:DeleteBackup",
      "dynamodb:UpdateContinuousBackups",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyDeleteElastiCacheSnapshots"
    effect = "Deny"
    actions = [
      "elasticache:DeleteSnapshot",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deny_destructive_backup" {
  name        = "${var.name}-deny-destructive-backup"
  description = "MANDATE-20: operators may not delete RDS/DDB/ElastiCache backups or disable DynamoDB PITR"
  policy      = data.aws_iam_policy_document.deny_destructive_backup.json
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "operator" {
  for_each = toset(var.attach_role_names)

  role       = each.value
  policy_arn = aws_iam_policy.deny_destructive_backup.arn
}

# Change trail: @hungxqt - 2026-07-20 - Mandate 20 backup protection and Valkey retention wiring.

