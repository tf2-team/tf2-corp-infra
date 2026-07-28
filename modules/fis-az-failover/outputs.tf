output "role_arn" {
  value       = aws_iam_role.fis.arn
  description = "IAM role ARN assumed by FIS for experiment actions"
}

output "template_ids" {
  value       = { for k, v in aws_fis_experiment_template.az_failover : k => v.id }
  description = "Map of Availability Zone to FIS experiment template ID"
}

output "template_arns" {
  value       = { for k, v in aws_fis_experiment_template.az_failover : k => "arn:${data.aws_partition.current.partition}:fis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:experiment-template/${v.id}" }
  description = "Map of Availability Zone to FIS experiment template ARN"
}

output "contract" {
  value = {
    schema_version        = "1.0"
    allowed_zones         = var.target_zones
    template_ids_by_zone  = { for k, v in aws_fis_experiment_template.az_failover : k => v.id }
    template_arns_by_zone = { for k, v in aws_fis_experiment_template.az_failover : k => "arn:${data.aws_partition.current.partition}:fis:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:experiment-template/${v.id}" }
    stop_alarm_arns       = var.stop_alarm_arns
    target_selectors_by_zone = {
      for zone in var.target_zones : zone => {
        ec2_cluster_name = var.eks_cluster_name
        subnet_ids       = lookup(var.subnet_ids_by_zone, zone, [])
        rds_arn          = var.rds_db_instance_arn
        valkey_arn       = var.valkey_replication_group_arn
      }
    }
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
  description = "Mandate 21 Person 1 -> Person 3 FIS contract schema"
}

# Change trail: @hungxqt - 2026-07-28 - Defined outputs and contract for fis-az-failover module.
