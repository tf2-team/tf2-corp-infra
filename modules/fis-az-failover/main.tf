data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "fis_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:fis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:experiment-template/*"]
    }
  }
}

resource "aws_iam_role" "fis" {
  name               = "${var.name_prefix}-fis-execution-role"
  assume_role_policy = data.aws_iam_policy_document.fis_assume_role.json

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-fis-execution-role"
    Mandate = "MD21"
    Purpose = "fis-execution-role"
  })
}

data "aws_iam_policy_document" "fis_policy" {
  statement {
    sid    = "AllowEC2InstanceActions"
    effect = "Allow"
    actions = [
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:RebootInstances",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"
    ]
  }

  statement {
    sid    = "AllowEC2ReadActions"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeNetworkAcls",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowNACLDisruptionActions"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkAcl",
      "ec2:CreateNetworkAclEntry",
      "ec2:DeleteNetworkAcl",
      "ec2:DeleteNetworkAclEntry",
      "ec2:ReplaceNetworkAclAssociation",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:vpc/${var.vpc_id}",
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-acl/*",
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/*",
    ]
  }

  statement {
    sid    = "AllowRDSFailoverActions"
    effect = "Allow"
    actions = [
      "rds:RebootDBInstance",
      "rds:DescribeDBInstances",
    ]
    resources = [var.rds_db_instance_arn]
  }

  statement {
    sid    = "AllowValkeyFailoverActions"
    effect = "Allow"
    actions = [
      "elasticache:TestFailover",
      "elasticache:DescribeReplicationGroups",
    ]
    resources = [var.valkey_replication_group_arn]
  }

  statement {
    sid    = "AllowS3EvidenceLogging"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${var.evidence_bucket_name}",
      "arn:${data.aws_partition.current.partition}:s3:::${var.evidence_bucket_name}/${var.evidence_prefix}*",
    ]
  }

  dynamic "statement" {
    for_each = var.evidence_kms_key_arn != "" ? [var.evidence_kms_key_arn] : []
    content {
      sid    = "AllowKMSEvidenceEncryption"
      effect = "Allow"
      actions = [
        "kms:GenerateDataKey*",
        "kms:Decrypt",
      ]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role_policy" "fis" {
  name   = "${var.name_prefix}-fis-policy"
  role   = aws_iam_role.fis.id
  policy = data.aws_iam_policy_document.fis_policy.json
}

resource "aws_fis_experiment_template" "az_failover" {
  for_each = toset(var.target_zones)

  description = "Mandate 21 immutable FIS AZ failover experiment template for ${each.key}"
  role_arn    = aws_iam_role.fis.arn

  dynamic "stop_condition" {
    for_each = var.stop_alarm_arns
    content {
      source = "aws:cloudwatch:alarm"
      value  = stop_condition.value
    }
  }

  log_configuration {
    log_schema_version = 2
    s3_configuration {
      bucket_name = var.evidence_bucket_name
      prefix      = "${var.evidence_prefix}${each.key}/"
    }
  }

  target {
    name           = "EC2Instances"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"
    parameters = {
      emptyTargetResolutionMode = "skip"
    }

    resource_tag {
      key   = "kubernetes.io/cluster/${var.eks_cluster_name}"
      value = "shared"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }

    filter {
      path   = "Placement.AvailabilityZone"
      values = [each.key]
    }
  }

  target {
    name           = "Subnets"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"
    parameters = {
      emptyTargetResolutionMode = "skip"
    }
    resource_arns = [
      for sub_id in lookup(var.subnet_ids_by_zone, each.key, []) :
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/${sub_id}"
    ]
  }

  target {
    name           = "RDSInstance"
    resource_type  = "aws:rds:db"
    selection_mode = "ALL"
    parameters = {
      emptyTargetResolutionMode = "skip"
    }
    resource_arns = [var.rds_db_instance_arn]

    filter {
      path   = "AvailabilityZone"
      values = [each.key]
    }
  }

  target {
    name           = "ValkeyReplicationGroup"
    resource_type  = "aws:elasticache:replication-group"
    selection_mode = "ALL"
    parameters = {
      emptyTargetResolutionMode = "skip"
    }
    resource_arns = [var.valkey_replication_group_arn]
  }

  action {
    name      = "StopEC2Instances"
    action_id = "aws:ec2:stop-instances"

    target {
      key   = "Instances"
      value = "EC2Instances"
    }

    parameter {
      key   = "startInstancesAfterDuration"
      value = "PT10M"
    }
  }

  action {
    name      = "DisruptSubnetNetwork"
    action_id = "aws:network:disrupt-connectivity"

    target {
      key   = "Subnets"
      value = "Subnets"
    }

    parameter {
      key   = "duration"
      value = "PT2M"
    }

    parameter {
      key   = "scope"
      value = "all"
    }
  }

  action {
    name      = "FailoverRDS"
    action_id = "aws:rds:reboot-db-instances"

    target {
      key   = "DBInstances"
      value = "RDSInstance"
    }

    parameter {
      key   = "forceFailover"
      value = "true"
    }
  }

  action {
    name      = "InterruptValkey"
    action_id = "aws:elasticache:replication-group-interrupt-az-power"

    target {
      key   = "ReplicationGroups"
      value = "ValkeyReplicationGroup"
    }

    parameter {
      key   = "duration"
      value = "PT10M"
    }
  }

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-az-failover-${each.key}"
    Zone    = each.key
    Mandate = "MD21"
    Purpose = "az-failover-experiment"
  })

  depends_on = [aws_iam_role_policy.fis]
}

# Change trail: @hungxqt - 2026-07-28 - Implemented main.tf for two-template FIS AZ failover module.
