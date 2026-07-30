data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

resource "aws_fis_experiment_template" "az_failover" {
  for_each = var.template_variants

  description = "Mandate 21 immutable FIS AZ failover experiment template ${each.key} for ${each.value.zone}"
  role_arn    = var.role_arn

  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "fail"
  }

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
      key   = "eks:nodegroup-name"
      value = "${var.eks_cluster_name}-system-${replace(each.value.zone, "us-east-", "")}"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }

    filter {
      path   = "Placement.AvailabilityZone"
      values = [each.value.zone]
    }
  }

  target {
    name           = "Subnets"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"
    resource_arns = [
      for sub_id in lookup(var.subnet_ids_by_zone, each.value.zone, []) :
      "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/${sub_id}"
    ]
  }

  dynamic "target" {
    for_each = each.value.rds_primary_relation == "inside" ? [each.value] : []

    content {
      name           = "RDSInstance"
      resource_type  = "aws:rds:db"
      selection_mode = "ALL"
      parameters = {
        availabilityZoneIdentifiers = target.value.zone
      }
      resource_tag {
        key   = "Name"
        value = var.rds_db_instance_identifier
      }
    }
  }

  target {
    name           = "ValkeyReplicationGroup"
    resource_type  = "aws:elasticache:replicationgroup"
    selection_mode = "ALL"
    parameters = {
      availabilityZoneIdentifier = each.value.zone
    }
    resource_tag {
      key   = "Name"
      value = var.valkey_replication_group_id
    }
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

    parameter {
      key   = "completeIfInstancesTerminated"
      value = "true"
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

  dynamic "action" {
    for_each = each.value.rds_primary_relation == "inside" ? [each.value] : []

    content {
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
    Name               = "${var.name_prefix}-az-failover-${each.key}"
    FaultZone          = each.value.zone
    RdsPrimaryRelation = each.value.rds_primary_relation
    TemplateVariant    = each.key
    CleanupPolicy      = "fis-native-verify-v1"
    Mandate            = "MD21"
    Purpose            = "az-failover-experiment"
  })
}

moved {
  from = aws_fis_experiment_template.az_failover["us-east-1a"]
  to   = aws_fis_experiment_template.az_failover["1a-primary-in"]
}

moved {
  from = aws_fis_experiment_template.az_failover["us-east-1b"]
  to   = aws_fis_experiment_template.az_failover["1b-primary-in"]
}

# Change trail: @hungxqt - 2026-07-29 - Added startInstancesAfterDuration, completeIfInstancesTerminated, and CleanupPolicy tag to FIS templates.
