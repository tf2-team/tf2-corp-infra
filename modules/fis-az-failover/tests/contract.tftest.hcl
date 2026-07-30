mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }
}

variables {
  name_prefix      = "test-fis"
  eks_cluster_name = "test-cluster"
  template_variants = {
    "1a-primary-in"      = { zone = "us-east-1a", rds_primary_relation = "inside" }
    "1a-primary-outside" = { zone = "us-east-1a", rds_primary_relation = "outside" }
    "1b-primary-in"      = { zone = "us-east-1b", rds_primary_relation = "inside" }
    "1b-primary-outside" = { zone = "us-east-1b", rds_primary_relation = "outside" }
  }
  subnet_ids_by_zone = {
    "us-east-1a" = ["subnet-11111111", "subnet-22222222"]
    "us-east-1b" = ["subnet-33333333", "subnet-44444444"]
  }
  rds_db_instance_identifier  = "test-db"
  valkey_replication_group_id = "test-valkey"
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

run "verify_four_variant_contract" {
  command = plan

  assert {
    condition = toset(keys(aws_fis_experiment_template.az_failover)) == toset([
      "1a-primary-in", "1a-primary-outside", "1b-primary-in", "1b-primary-outside",
    ])
    error_message = "Exactly the four stable template variant keys must be created."
  }

  assert {
    condition     = output.contract.schema_version == "2.0"
    error_message = "Contract schema_version must be 2.0."
  }

  assert {
    condition     = toset(output.contract.allowed_zones) == toset(["us-east-1a", "us-east-1b"])
    error_message = "Contract allowed_zones must remain the two production AZs."
  }

  assert {
    condition = alltrue([
      toset(keys(output.template_ids_by_variant)) == toset(keys(aws_fis_experiment_template.az_failover)),
      toset(keys(output.template_arns_by_variant)) == toset(keys(aws_fis_experiment_template.az_failover)),
      toset(keys(output.contract.template_ids_by_variant)) == toset(keys(aws_fis_experiment_template.az_failover)),
      toset(keys(output.contract.template_arns_by_variant)) == toset(keys(aws_fis_experiment_template.az_failover)),
      toset(keys(output.contract.templates)) == toset(keys(aws_fis_experiment_template.az_failover)),
    ])
    error_message = "All schema 2.0 template maps must use the four stable variant keys."
  }

  assert {
    condition = length(output.contract.stop_alarm_arns) == 4 && alltrue([
      for template in values(aws_fis_experiment_template.az_failover) :
      length(template.stop_condition) == 4
    ])
    error_message = "The contract and every template must retain exactly four stop alarms."
  }

  assert {
    condition = alltrue([
      for template in values(aws_fis_experiment_template.az_failover) :
      one(template.experiment_options).account_targeting == "single-account" &&
      one(template.experiment_options).empty_target_resolution_mode == "fail"
    ])
    error_message = "Every template must use single-account targeting and fail on empty targets."
  }

  assert {
    condition = alltrue([
      for key in ["1a-primary-in", "1b-primary-in"] :
      length([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]) == 1 &&
      one([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]).resource_type == "aws:rds:db" &&
      one([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]).parameters["availabilityZoneIdentifiers"] == output.contract.templates[key].zone &&
      one(one([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]).resource_tag).value == "test-db" &&
      length([for action in aws_fis_experiment_template.az_failover[key].action : action if action.name == "FailoverRDS"]) == 1 &&
      one([for action in aws_fis_experiment_template.az_failover[key].action : action if action.name == "FailoverRDS"]).action_id == "aws:rds:reboot-db-instances" &&
      one([for parameter in one([for action in aws_fis_experiment_template.az_failover[key].action : action if action.name == "FailoverRDS"]).parameter : parameter if parameter.key == "forceFailover"]).value == "true"
    ])
    error_message = "Primary-in variants must include the exact RDS DB failover target and forceFailover action."
  }

  assert {
    condition = alltrue([
      for key in ["1a-primary-outside", "1b-primary-outside"] :
      length([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]) == 0 &&
      length([for action in aws_fis_experiment_template.az_failover[key].action : action if action.name == "FailoverRDS"]) == 0 &&
      output.contract.templates[key].target_selectors.rds == null &&
      output.contract.templates[key].includes_rds_failover == false
    ])
    error_message = "Primary-outside variants must omit both RDS target and action and publish a null RDS selector."
  }

  assert {
    condition = alltrue([
      for key in ["1a-primary-in", "1b-primary-in"] :
      output.contract.templates[key].target_selectors.rds != null &&
      output.contract.templates[key].includes_rds_failover == true &&
      output.contract.templates[key].target_selectors.rds.resource_type == "aws:rds:db"
    ])
    error_message = "Primary-in contract entries must publish the RDS selector and failover flag."
  }

  assert {
    condition = alltrue([
      for key, template in aws_fis_experiment_template.az_failover :
      toset([for target in template.target : target.name]) == (
        output.contract.templates[key].includes_rds_failover
        ? toset(["EC2Instances", "Subnets", "RDSInstance", "ValkeyReplicationGroup"])
        : toset(["EC2Instances", "Subnets", "ValkeyReplicationGroup"])
      ) &&
      toset([for action in template.action : action.name]) == (
        output.contract.templates[key].includes_rds_failover
        ? toset(["StopEC2Instances", "DisruptSubnetNetwork", "FailoverRDS", "InterruptValkey"])
        : toset(["StopEC2Instances", "DisruptSubnetNetwork", "InterruptValkey"])
      )
    ])
    error_message = "Variants must retain only the intended EC2, subnet, Valkey, and conditional RDS targets/actions."
  }

  assert {
    condition = alltrue([
      for key, template in aws_fis_experiment_template.az_failover :
      one([for target in template.target : target if target.name == "Subnets"]).resource_arns == toset([
        for subnet_id in var.subnet_ids_by_zone[output.contract.templates[key].zone] :
        "arn:aws:ec2:us-east-1:123456789012:subnet/${subnet_id}"
      ]) &&
      one([for target in template.target : target if target.name == "ValkeyReplicationGroup"]).resource_arns == null &&
      length(one([for target in template.target : target if target.name == "ValkeyReplicationGroup"]).filter) == 0 &&
      one(one([for target in template.target : target if target.name == "ValkeyReplicationGroup"]).resource_tag).key == "Name" &&
      one(one([for target in template.target : target if target.name == "ValkeyReplicationGroup"]).resource_tag).value == "test-valkey"
    ])
    error_message = "Subnet ARNs and Valkey Name-tag selectors must remain exact for every fault-zone variant."
  }

  assert {
    condition = alltrue([
      for key in ["1a-primary-in", "1b-primary-in"] :
      one([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]).resource_arns == null &&
      length(one([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]).filter) == 0 &&
      one(one([for target in aws_fis_experiment_template.az_failover[key].target : target if target.name == "RDSInstance"]).resource_tag).key == "Name"
    ])
    error_message = "Primary-in RDS selectors must use only the exact Name tag plus AZ parameter, without ARNs or filters."
  }

  assert {
    condition = alltrue([
      for key, template in aws_fis_experiment_template.az_failover :
      template.tags["FaultZone"] == output.contract.templates[key].zone &&
      template.tags["RdsPrimaryRelation"] == output.contract.templates[key].rds_primary_relation &&
      template.tags["TemplateVariant"] == key
    ])
    error_message = "Every template must expose FaultZone, RdsPrimaryRelation, and TemplateVariant tags."
  }

  assert {
    condition = alltrue([
      for key, template in aws_fis_experiment_template.az_failover :
      one([for target in template.target : target if target.name == "ValkeyReplicationGroup"]).parameters["availabilityZoneIdentifier"] == output.contract.templates[key].zone &&
      output.contract.templates[key].target_selectors.valkey.availability_zone_identifier == output.contract.templates[key].zone &&
      output.contract.templates[key].target_selectors.ec2.zone_filter.values == [output.contract.templates[key].zone]
    ])
    error_message = "Each template contract must publish selectors for its exact fault zone."
  }

  assert {
    condition = alltrue([
      for key, template in aws_fis_experiment_template.az_failover :
      length([for action in template.action : action if action.name == "StopEC2Instances"]) == 1 &&
      one([for p in one([for action in template.action : action if action.name == "StopEC2Instances"]).parameter : p if p.key == "startInstancesAfterDuration"]).value == "PT10M" &&
      one([for p in one([for action in template.action : action if action.name == "StopEC2Instances"]).parameter : p if p.key == "completeIfInstancesTerminated"]).value == "true"
    ])
    error_message = "Every StopEC2Instances action must configure startInstancesAfterDuration and completeIfInstancesTerminated."
  }

  assert {
    condition = alltrue([
      for key, template in aws_fis_experiment_template.az_failover :
      template.tags["CleanupPolicy"] == "fis-native-verify-v1"
    ])
    error_message = "Every template must expose tag CleanupPolicy = fis-native-verify-v1."
  }

  assert {
    condition = alltrue([
      for key, template_contract in output.contract.templates :
      template_contract.cleanup.policyVersion == 1 &&
      template_contract.cleanup.mode == "verify-only" &&
      template_contract.cleanup.timeoutMinutes == 45 &&
      template_contract.cleanup.pollIntervalSeconds == 15 &&
      template_contract.cleanup.requiredAlarmWindows == 2 &&
      template_contract.cleanup.expected.ec2AutoRestart == true &&
      template_contract.cleanup.expected.allowInstanceReplacement == true &&
      template_contract.cleanup.expected.networkAclRestore == true &&
      template_contract.cleanup.expected.valkeyRecovery == true &&
      template_contract.cleanup.expected.rdsFailoverExpected == (template_contract.rds_primary_relation == "inside")
    ])
    error_message = "Every contract template entry must expose static cleanup policy matching expected RDS failover relation."
  }
}

run "reject_invalid_template_variant_contract" {
  command = plan

  variables {
    template_variants = {
      "1a-primary-in"      = { zone = "us-east-1a", rds_primary_relation = "inside" }
      "1a-primary-outside" = { zone = "us-east-1a", rds_primary_relation = "outside" }
      "1b-primary-in"      = { zone = "us-east-1b", rds_primary_relation = "inside" }
    }
  }

  expect_failures = [var.template_variants]
}

# Change trail: @hungxqt - 2026-07-29 - Verified completeIfInstancesTerminated parameter, CleanupPolicy tag, and template cleanup contract.
