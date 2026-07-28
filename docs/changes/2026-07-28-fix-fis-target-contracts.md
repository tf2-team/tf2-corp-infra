# Change: Fix AWS FIS Target Contracts and Execution Permissions

## Summary

Corrected the Mandate 21 AWS Fault Injection Service target contract and experiment-role permissions. RDS targets now avoid the invalid ARN-plus-filter combination while retaining zonal intent through a target parameter, Valkey targets include their required AZ parameter, experiments fail closed when targets resolve empty, and the bootstrap role includes the permissions required by the configured EC2, network, RDS, and ElastiCache actions.

## Context

AWS rejected CreateExperimentTemplate for RDSInstance because the submitted target combined resource ARNs with a resource filter. Commit 8a40646 removed that invalid filter and corrected the ElastiCache identifiers, but deeper verification against the AWS FIS action and target references found that both per-AZ data-service targets still lacked their AZ parameters and that the experiment role could not execute all configured actions.

Constraints shaping the change:

- techx-corp-infra production uses AWS provider 5.100.0; the standalone module test lock currently uses 6.56.0.
- No AWS resources were changed during this work.
- Bootstrap owns the pre-created FIS experiment role, so bootstrap must be deployed before the production composition.
- The original EC2 resource-tag plus filters selector is valid and remains unchanged.

## Before

- RDSInstance had one explicit DB ARN. The earlier invalid AvailabilityZone filter had been removed, but the target no longer carried per-template AZ selection semantics.
- ValkeyReplicationGroup used the supported resource type and action ID but omitted the required availabilityZoneIdentifier target parameter.
- Experiment empty-target behavior was implicit.
- The bootstrap role granted elasticache:TestFailover rather than the InterruptClusterAzPower operation used by the configured action.
- The role omitted tag:GetResources, required network-disruption discovery/tagging actions, and kms:CreateGrant for restarting instances with encrypted EBS volumes.
- The native module test checked output counts but not the rendered target definitions.

## After

- Each RDSInstance target uses its explicit ARN, has no filter, and sets availabilityZoneIdentifiers to the template AZ.
- Each ValkeyReplicationGroup target sets the required availabilityZoneIdentifier to the template AZ.
- Experiment options explicitly use single-account targeting and fail when any required target resolves empty.
- The bootstrap role grants the exact ElastiCache mutation used by AWS FIS, separates discovery permissions onto wildcard resources, supports tag resolution and network ACL orchestration, and conditionally allows KMS grants for AWS resources.
- Native tests render both AZ templates through a mock provider and verify the target contract.

## Technical Design Decisions

Explicit resource ARNs remain the source of identity for RDS and Valkey. AWS prohibits combining a resource ID with a resource filter, but target parameters are the supported mechanism for AZ-specific RDS and ElastiCache selection. This preserves deterministic resource identity without broad tag selection.

Fail mode was chosen for empty target resolution because these are resilience-control experiments: silently skipping a missing RDS, Valkey, EC2, or subnet target would produce misleading evidence. IAM changes follow the permissions listed for the selected actions and keep mutation permissions ARN-scoped where AWS supports it. Discovery-only actions remain Resource = * where service APIs do not provide useful resource-level scoping.

The production provider constraint was not upgraded. The standalone provider 6.56.0 test emits a deprecation warning for data.aws_region.current.name, while production provider 5.100.0 still uses that established attribute. Resolving that warning requires a separately reviewed provider-version alignment rather than mixing an upgrade into this FIS fix.

## Implementation Details

1. Added mock data for caller identity, partition, and Region to the native module test.
2. Added assertions over every rendered experiment template for RDS filters and AZ parameters and for the Valkey resource type and required AZ parameter.
3. Added fail-closed single-account experiment options.
4. Added availabilityZoneIdentifiers to RDS targets and availabilityZoneIdentifier to Valkey targets.
5. Added EC2 prefix-list discovery and CreateTags permissions required by network disruption.
6. Replaced elasticache:TestFailover with elasticache:InterruptClusterAzPower and separated describe permissions.
7. Added tag:GetResources and a kms:GrantIsForAWSResource-conditioned kms:CreateGrant statement.
8. Ran formatting, validation, native tests, and static security scans without applying Terraform.

## Files Changed

**Bootstrap:**

- bootstrap/main.tf — Completed the FIS experiment-role permissions for all configured actions.

**Module:**

- modules/fis-az-failover/main.tf — Added valid zonal target parameters and fail-closed experiment options.
- modules/fis-az-failover/tests/contract.tftest.hcl — Added mock-provider regression coverage for rendered RDS and Valkey targets.

**Documentation:**

- docs/plan/2026-07-28-fis-contract-hardening.md — Records the implementation and rollout sequence.
- docs/changes/2026-07-28-fix-fis-target-contracts.md — This change record.

## Dependencies and Cross-Repository Impact

None. The change is fully contained in techx-corp-infra. The bootstrap stack and production stack are separate Terraform roots inside this repository and must be deployed in that order.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No normal application runtime change; only FIS experiment behavior changes. |
| **Infrastructure** | Updates one bootstrap IAM inline policy and two FIS experiment templates after deployment. |
| **Deployment** | Requires a reviewed bootstrap plan/apply before the reviewed production plan/apply. |
| **Performance** | No steady-state impact. |
| **Security** | Adds only action-required permissions; KMS grant creation is conditioned to AWS resources. |
| **Reliability** | Prevents invalid templates and fails experiments when required targets resolve empty. |
| **Cost** | No steady-state resource cost; FIS experiment execution and logging retain their existing usage costs. |
| **Backward compatibility** | Terraform resource addresses and module call shape are unchanged. |
| **Observability** | Existing S3 FIS logging remains enabled; fail-closed target resolution makes missing-target failures explicit. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Formatting | terraform fmt and terraform fmt -check on affected HCL | Pass after formatting |
| Module validation | terraform -chdir=modules/fis-az-failover validate -no-color | Pass |
| Bootstrap validation | terraform -chdir=bootstrap validate -no-color | Pass |
| Native regression test | terraform test -no-color | Pass: 1 passed, 0 failed |
| Bootstrap lint | tflint --chdir=bootstrap --format=compact | Pass |
| Module lint | tflint --chdir=modules/fis-az-failover --format=compact | Existing five unused-input warnings; no new target error |
| Checkov | checkov on affected Terraform files | Pass: 45 passed, 0 failed, 2 skipped |
| Trivy | trivy config with HIGH,CRITICAL threshold | Pass: zero findings in module and bootstrap |
| Diff whitespace | git diff --check | Pass |

### Manual Verification

- Verified the pre-change native test failed because RDS and Valkey parameters rendered null.
- Verified the post-change plan-mode test renders us-east-1a and us-east-1b into the correct parameter keys.
- Compared action IDs, resource types, parameters, and permissions with current AWS FIS primary documentation.
- Live AWS CLI action inspection was unavailable because the local environment forces AWS traffic through an unreachable proxy.

### Remaining Verification (Post-Merge)

- Produce and review a saved bootstrap plan; operator approval required.
- Apply bootstrap, then produce and review the production plan; operator approval required.
- Generate an FIS target preview for each template and verify the EC2 instances, subnets, RDS DB, and Valkey nodes resolve in the expected AZ.
- Start no experiment until alarms are OK and the owner explicitly approves the blast radius.

## Migration or Deployment Notes

1. From techx-corp-infra\bootstrap, generate a saved Terraform plan and review the IAM policy delta.
2. Apply only the reviewed bootstrap plan after explicit operator approval.
3. From techx-corp-infra\environments\production, generate a new saved plan after bootstrap completes.
4. Confirm the plan updates both FIS experiment templates without replacing unrelated resources.
5. Apply only the reviewed production plan after explicit operator approval.
6. Generate an FIS target preview and confirm every required target resolves before starting an experiment.

No direct mutating AWS command is part of this change.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| A target resolves empty because the selected service is not present in that AZ | Medium | Medium | Fail-closed behavior exposes the mismatch; inspect target preview and correct the AZ/resource topology. |
| Bootstrap permissions are not deployed before template execution | Medium | High | Enforce bootstrap-first rollout and inspect experiment AuthorizationFailure details. |
| Network disruption affects more tagged EC2 instances or subnets than intended | Low | High | Review explicit subnet ARNs and target preview; retain stop alarms and require execution approval. |
| Provider-version drift changes warnings or schema behavior | Low | Medium | Keep production on its locked provider for this change and handle provider alignment separately. |

**Rollback procedure:**

1. Revert this change in Git.
2. Generate and review a bootstrap plan that restores the prior inline policy; apply it only with explicit approval.
3. Generate and review a production plan that restores the prior experiment-template definitions; apply it only with explicit approval.
4. Do not start an experiment while rollback is in progress.

<!-- Change trail: @hungxqt - 2026-07-28 - Recorded FIS target-contract and execution-role remediation. -->