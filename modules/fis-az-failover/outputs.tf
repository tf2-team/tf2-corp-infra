output "role_arn" {
  value       = var.role_arn
  description = "IAM role ARN assumed by FIS for experiment actions"
}

output "template_ids_by_variant" {
  value       = { for k, v in aws_fis_experiment_template.az_failover : k => v.id }
  description = "Map of stable template variant key to FIS experiment template ID"
}

output "template_arns_by_variant" {
  value       = { for k, v in aws_fis_experiment_template.az_failover : k => "arn:${data.aws_partition.current.partition}:fis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:experiment-template/${v.id}" }
  description = "Map of stable template variant key to FIS experiment template ARN"
}

output "contract" {
  value = {
    schema_version = "2.0"
    allowed_zones = sort(distinct([
      for variant in values(var.template_variants) : variant.zone
    ]))
    template_ids_by_variant  = { for k, v in aws_fis_experiment_template.az_failover : k => v.id }
    template_arns_by_variant = { for k, v in aws_fis_experiment_template.az_failover : k => "arn:${data.aws_partition.current.partition}:fis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:experiment-template/${v.id}" }
    templates = {
      for variant_key, template in aws_fis_experiment_template.az_failover : variant_key => {
        id                    = template.id
        arn                   = "arn:${data.aws_partition.current.partition}:fis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:experiment-template/${template.id}"
        zone                  = var.template_variants[variant_key].zone
        rds_primary_relation  = var.template_variants[variant_key].rds_primary_relation
        includes_rds_failover = var.template_variants[variant_key].rds_primary_relation == "inside"
        target_selectors = {
          ec2 = {
            cluster_resource_tag = {
              key   = "eks:nodegroup-name"
              value = "${var.eks_cluster_name}-system-${replace(var.template_variants[variant_key].zone, "us-east-", "")}"
            }
            state_filter = {
              path   = "State.Name"
              values = ["running"]
            }
            zone_filter = {
              path   = "Placement.AvailabilityZone"
              values = [var.template_variants[variant_key].zone]
            }
          }
          subnet_ids = lookup(var.subnet_ids_by_zone, var.template_variants[variant_key].zone, [])
          rds = var.template_variants[variant_key].rds_primary_relation == "inside" ? {
            resource_type = "aws:rds:db"
            resource_tag = {
              key   = "Name"
              value = var.rds_db_instance_identifier
            }
            availability_zone_identifier = var.template_variants[variant_key].zone
          } : null
          valkey = {
            resource_type = "aws:elasticache:replicationgroup"
            resource_tag = {
              key   = "Name"
              value = var.valkey_replication_group_id
            }
            availability_zone_identifier = var.template_variants[variant_key].zone
          }
        }
        cleanup = {
          policyVersion        = 1
          mode                 = "verify-only"
          timeoutMinutes       = 45
          pollIntervalSeconds  = 15
          requiredAlarmWindows = 2
          expected = {
            ec2AutoRestart           = true
            allowInstanceReplacement = true
            networkAclRestore        = true
            rdsFailoverExpected      = var.template_variants[variant_key].rds_primary_relation == "inside"
            valkeyRecovery           = true
          }
        }
      }
    }
    stop_alarm_arns = var.stop_alarm_arns
    fault_durations = {
      compute_fault_duration = "PT10M"
      network_fault_duration = "PT2M"
      valkey_fault_duration  = "PT10M"
    }
    evidence = {
      bucket = var.evidence_bucket_name
      prefix = var.evidence_prefix
    }
    cleanup = {
      terminal_states = ["completed", "stopped", "failed"]
      assertions = [
        "No temporary NACL left associated",
        "No experiment EC2 instance remains stopped",
        "RDS and Valkey primary endpoints healthy",
        "All stop alarms return to OK",
      ]
    }
  }
  description = "Mandate 21 Person 1 to Person 3 FIS contract schema keyed by stable template variant"
}

# Change trail: @hungxqt - 2026-07-29 - Added static cleanup policy configuration to contract templates.
