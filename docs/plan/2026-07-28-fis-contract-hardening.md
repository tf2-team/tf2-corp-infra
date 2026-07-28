# FIS Contract Hardening Implementation Plan

> **For agentic workers:** Execute this plan task-by-task and preserve the bootstrap-before-production deployment order.

**Goal:** Make the Mandate 21 AWS FIS templates valid at creation time and executable with the intended per-AZ targets and least-required service permissions.

**Architecture:** Keep one experiment template per Availability Zone. Retain explicit subnet ARNs, use exact Name tags plus target parameters for RDS and Valkey AZ scoping, reserve filters for the tag-selected EC2 target, and keep action parameters on their actions. Keep the experiment role in bootstrap and grant only permissions required by the configured actions.

**Tech Stack:** Terraform 1.15.x, HashiCorp AWS provider 5.100.0 in production, AWS provider 6.56.0 in standalone module tests, AWS Fault Injection Service, and native Terraform tests.

---

### Task 1: Lock the target contract with tests

**Files:**

- Modify: modules/fis-az-failover/tests/contract.tftest.hcl

- [x] Add a mock AWS provider with deterministic account, partition, and Region data.
- [x] Assert that RDS targets have no ARNs or filters, use the exact Name tag, and use the template AZ through availabilityZoneIdentifiers.
- [x] Assert that Valkey targets have no ARNs, use the exact Name tag, and use the required availabilityZoneIdentifier.
- [x] Run the test before implementation and confirm both assertions fail because ARNs are present and resource tags are absent.

### Task 2: Correct the FIS module

**Files:**

- Modify: modules/fis-az-failover/main.tf
- Modify: modules/fis-az-failover/outputs.tf
- Modify: modules/commerce-ha/main.tf

- [x] Configure single-account, fail-closed experiment options.
- [x] Replace the RDS ARN selector with its exact Name tag and retain the per-template availabilityZoneIdentifiers parameter.
- [x] Replace the Valkey ARN selector with its exact Name tag and retain the required availabilityZoneIdentifier parameter.
- [x] Add the deterministic Name tag to the Terraform-managed Valkey replication group and retain forceFailover and duration as action parameters.

### Task 3: Correct the bootstrap experiment role

**Files:**

- Modify: bootstrap/main.tf

- [x] Add the network-disruption discovery and tagging permissions documented by AWS FIS.
- [x] Replace elasticache:TestFailover with elasticache:InterruptClusterAzPower.
- [x] Separate RDS and ElastiCache discovery permissions from ARN-scoped mutations.
- [x] Add tag:GetResources for EC2 tag target resolution.
- [x] Add condition-scoped kms:CreateGrant for restarting instances backed by encrypted EBS volumes.

### Task 4: Validate and deploy safely

**Files:**

- Create: docs/changes/2026-07-28-fix-fis-target-contracts.md

- [x] Run Terraform formatting, validation, and the native module test.
- [x] Run TFLint, Checkov, and Trivy static checks.
- [ ] Review and apply a saved bootstrap plan under a separate operator approval.
- [ ] Review and apply a saved production plan after bootstrap completes.
- [ ] Generate an AWS FIS target preview and verify resolved resources before starting an experiment.

CMD validation commands:

~~~cmd
cd /d techx-corp-infra\modules\fis-az-failover
terraform test -no-color
terraform validate -no-color
~~~

~~~cmd
cd /d techx-corp-infra\bootstrap
terraform validate -no-color
tflint --format=compact
~~~

<!-- Change trail: @hungxqt - 2026-07-28 - Corrected the FIS selector plan from ARN-based to tag-based targeting. -->
