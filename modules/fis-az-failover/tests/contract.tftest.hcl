run "verify_two_az_contract" {
  command = plan

  variables {
    name_prefix      = "test-fis"
    vpc_id           = "vpc-12345678"
    eks_cluster_name = "test-cluster"
    target_zones     = ["us-east-1a", "us-east-1b"]
    subnet_ids_by_zone = {
      "us-east-1a" = ["subnet-11111111", "subnet-22222222"]
      "us-east-1b" = ["subnet-33333333", "subnet-44444444"]
    }
    rds_db_instance_arn         = "arn:aws:rds:us-east-1:123456789012:db:test-db"
    rds_db_instance_identifier  = "test-db"
    valkey_replication_group_arn = "arn:aws:elasticache:us-east-1:123456789012:replicationgroup:test-valkey"
    valkey_replication_group_id  = "test-valkey"
    stop_alarm_arns = [
      "arn:aws:cloudwatch:us-east-1:123456789012:alarm:alarm1",
      "arn:aws:cloudwatch:us-east-1:123456789012:alarm:alarm2",
      "arn:aws:cloudwatch:us-east-1:123456789012:alarm:alarm3",
      "arn:aws:cloudwatch:us-east-1:123456789012:alarm:alarm4",
    ]
    evidence_bucket_name = "test-evidence-bucket"
    evidence_prefix      = "mandate-21/fis/"
    role_arn             = "arn:aws:iam::123456789012:role/test-fis-role"
  }

  assert {
    condition     = length(output.contract.allowed_zones) == 2
    error_message = "Contract allowed_zones must have exactly 2 AZs."
  }

  assert {
    condition     = output.contract.schema_version == "1.0"
    error_message = "Contract schema_version must be 1.0."
  }

  assert {
    condition     = length(output.contract.stop_alarm_arns) == 4
    error_message = "Contract must require 4 stop alarm ARNs."
  }
}

# Change trail: @hungxqt - 2026-07-28 - Added native contract tests for fis-az-failover module.
