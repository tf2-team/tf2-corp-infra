# FIS Contract Hardening Implementation Plan

> **For agentic workers:** Execute this plan task-by-task and preserve the bootstrap-before-production deployment order.

**Goal:** Make the Mandate 21 AWS FIS templates valid at creation time and executable with the intended per-AZ targets and least-required service permissions.

**Architecture:** Keep one experiment template per Availability Zone and retain explicit RDS, subnet, and Valkey ARNs. Use target parameters for RDS and ElastiCache AZ scoping, reserve filters for the tag-selected EC2 target, and keep action parameters on their actions. Keep the experiment role in bootstrap and grant only permissions required by the configured actions.

**Tech Stack:** Terraform 1.15.x, HashiCorp AWS provider 5.100.0 in production, AWS provider 6.56.0 in standalone module tests, AWS Fault Injection Service, and native Terraform tests.

---

### Task 1: Lock the target contract with tests

**Files:**

- Modify: modules/fis-az-failover/tests/contract.tftest.hcl

- [x] Add a mock AWS provider with deterministic account, partition, and Region data.
- [x] Assert that RDS targets have no filters and use the template AZ through availabilityZoneIdentifiers.
- [x] Assert that Valkey targets use aws:elasticache:replicationgroup and the required availabilityZoneIdentifier.
- [x] Run the test before implementation and confirm both assertions fail with parameters = null.

### Task 2: Correct the FIS module

**Files:**

- Modify: modules/fis-az-failover/main.tf

- [x] Configure single-account, fail-closed experiment options.
- [x] Add the per-template RDS availabilityZoneIdentifiers target parameter without reintroducing an ARN/filter conflict.
- [x] Add the required Valkey availabilityZoneIdentifier target parameter.
- [x] Retain forceFailover and duration as action parameters.

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

<!-- Change trail: @hungxqt - 2026-07-28 - Documented the completed FIS contract-hardening implementation and rollout gates. -->