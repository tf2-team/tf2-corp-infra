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
  target          = module.fis_az_failover.aws_fis_experiment_template.az_failover
  override_during = plan
  values = {
    id = "EXT00000000000000"
  }
}
run "mandate21_four_variant_contract" {
  command = plan

  plan_options {
    target = [module.fis_az_failover]
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
      output.mandate21_fis_contract.zones["us-east-1a"].primaryInZoneTemplateId == output.mandate21_fis_template_ids["1a-primary-in"],
      output.mandate21_fis_contract.zones["us-east-1a"].primaryOutsideZoneTemplateId == output.mandate21_fis_template_ids["1a-primary-outside"],
      output.mandate21_fis_contract.zones["us-east-1b"].primaryInZoneTemplateId == output.mandate21_fis_template_ids["1b-primary-in"],
      output.mandate21_fis_contract.zones["us-east-1b"].primaryOutsideZoneTemplateId == output.mandate21_fis_template_ids["1b-primary-outside"],
    ])
    error_message = "Person 3 contract must map both template relations for both fault AZs."
  }

  assert {
    condition     = jsondecode(jsonencode(output.mandate21_fis_contract)).schemaVersion == 1
    error_message = "Person 3 contract must remain JSON round-trip parseable."
  }

  assert {
    condition     = length(output.mandate21_stop_alarm_arns) == 4
    error_message = "Production must wire exactly four fail-closed stop alarms."
  }
}

# Change trail: @hungxqt - 2026-07-28 - Verified the exact wrapper-compatible four-template Mandate 21 output contract.