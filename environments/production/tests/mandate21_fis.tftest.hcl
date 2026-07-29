mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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

mock_provider "aws" {
  alias = "cur"
}

mock_provider "archive" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}
mock_provider "tls" {}

override_resource {
  target          = module.fis_az_failover.aws_fis_experiment_template.az_failover["1a-primary-in"]
  override_during = plan
  values = {
    id  = "EXT1A00000000001"
    arn = "arn:aws:fis:us-east-1:123456789012:experiment-template/EXT1A00000000001"
  }
}

override_resource {
  target          = module.fis_az_failover.aws_fis_experiment_template.az_failover["1a-primary-outside"]
  override_during = plan
  values = {
    id  = "EXT1A00000000002"
    arn = "arn:aws:fis:us-east-1:123456789012:experiment-template/EXT1A00000000002"
  }
}

override_resource {
  target          = module.fis_az_failover.aws_fis_experiment_template.az_failover["1b-primary-in"]
  override_during = plan
  values = {
    id  = "EXT1B00000000001"
    arn = "arn:aws:fis:us-east-1:123456789012:experiment-template/EXT1B00000000001"
  }
}

override_resource {
  target          = module.fis_az_failover.aws_fis_experiment_template.az_failover["1b-primary-outside"]
  override_during = plan
  values = {
    id  = "EXT1B00000000002"
    arn = "arn:aws:fis:us-east-1:123456789012:experiment-template/EXT1B00000000002"
  }
}

override_resource {
  target = module.rds_postgresql.aws_db_instance.this
  values = {
    id         = "techx-prod-tf2-postgresql"
    identifier = "techx-prod-tf2-postgresql"
  }
}

run "mandate21_four_variant_contract" {
  command = plan

  plan_options {
    target = [
      module.fis_az_failover,
      module.rds_postgresql,
    ]
  }

  assert {
    condition = toset(keys(output.mandate21_fis_template_ids)) == toset([
      "1a-primary-in", "1a-primary-outside", "1b-primary-in", "1b-primary-outside",
      ]) && toset(keys(output.mandate21_fis_template_arns)) == toset([
      "1a-primary-in", "1a-primary-outside", "1b-primary-in", "1b-primary-outside",
    ])
    error_message = "Production FIS ID and ARN outputs must use exactly the four stable variant keys."
  }

  assert {
    condition = toset(keys(output.mandate21_fis_contract)) == toset([
      "schemaVersion",
      "region",
      "clusterContext",
      "namespace",
      "storefrontUrl",
      "rdsInstanceIdentifier",
      "zones",
      "cleanupByTemplateId",
    ])
    error_message = "Person 3 contract must expose exactly the required wrapper fields."
  }

  assert {
    condition = alltrue([
      output.mandate21_fis_contract.schemaVersion == 1,
      output.mandate21_fis_contract.region == "us-east-1",
      output.mandate21_fis_contract.clusterContext == "arn:aws:eks:us-east-1:123456789012:cluster/techx-tf2-prod",
      output.mandate21_fis_contract.namespace == "techx-corp-prod",
      output.mandate21_fis_contract.storefrontUrl == "https://hungtran.id.vn",
      output.mandate21_fis_contract.rdsInstanceIdentifier == "techx-prod-tf2-postgresql",
    ])
    error_message = "Person 3 runtime context must match the Mandate 21 handoff contract."
  }

  assert {
    condition = toset(keys(output.mandate21_fis_contract.zones)) == toset(["us-east-1a", "us-east-1b"]) && alltrue([
      contains(keys(output.mandate21_fis_contract.zones["us-east-1a"]), "primaryInZoneTemplateId"),
      contains(keys(output.mandate21_fis_contract.zones["us-east-1a"]), "primaryOutsideZoneTemplateId"),
      contains(keys(output.mandate21_fis_contract.zones["us-east-1b"]), "primaryInZoneTemplateId"),
      contains(keys(output.mandate21_fis_contract.zones["us-east-1b"]), "primaryOutsideZoneTemplateId"),
    ])
    error_message = "Person 3 contract must map both template relations for both fault AZs."
  }

  assert {
    condition = toset(keys(output.mandate21_fis_contract.cleanupByTemplateId)) == toset([
      "EXT1A00000000001",
      "EXT1A00000000002",
      "EXT1B00000000001",
      "EXT1B00000000002",
    ]) && alltrue([
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].variant == "1a-primary-in",
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].rdsFailoverExpected == true,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000002"].variant == "1a-primary-outside",
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000002"].rdsFailoverExpected == false,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1B00000000001"].variant == "1b-primary-in",
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1B00000000001"].rdsFailoverExpected == true,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1B00000000002"].variant == "1b-primary-outside",
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1B00000000002"].rdsFailoverExpected == false,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].policyVersion == 1,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].mode == "verify-only",
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].timeoutMinutes == 45,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].pollIntervalSeconds == 15,
      output.mandate21_fis_contract.cleanupByTemplateId["EXT1A00000000001"].requiredAlarmWindows == 2,
    ])
    error_message = "cleanupByTemplateId must map all four template IDs to their cleanup policy parameters."
  }

  assert {
    condition     = output.mandate21_fis_contract.schemaVersion == 1
    error_message = "Person 3 contract must specify schemaVersion 1."
  }

  assert {
    condition     = length(output.mandate21_stop_alarm_arns) == 4
    error_message = "Production must wire exactly four fail-closed stop alarms."
  }
}

# Change trail: @hungxqt - 2026-07-29 - Verified cleanupByTemplateId field and policy entries in production test contract.