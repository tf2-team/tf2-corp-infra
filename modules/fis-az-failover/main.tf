data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_fis_experiment_template" "az_failover" {
  for_each = toset(var.target_zones)

  description = "Mandate 21 immutable FIS AZ failover experiment template for ${each.key}"
  role_arn    = var.role_arn

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
    resource_arns = [
      for sub_id in lookup(var.subnet_ids_by_zone, each.key, []) :
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/${sub_id}"
    ]
  }

  target {
    name           = "RDSInstance"
    resource_type  = "aws:rds:db"
    selection_mode = "ALL"
    resource_arns  = [var.rds_db_instance_arn]
  }

  target {
    name           = "ValkeyReplicationGroup"
    resource_type  = "aws:elasticache:replicationgroup"
    selection_mode = "ALL"
    resource_arns  = [var.valkey_replication_group_arn]
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
    action_id = "aws:elasticache:replicationgroup-interrupt-az-power"

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
}

# Change trail: @hungxqt - 2026-07-28 - Aligned FIS targets and action IDs with AWS FIS schema specifications.
