# Change: Fix AWS FIS Target Contracts and Execution Permissions

## Summary

Corrected the Mandate 21 AWS Fault Injection Service target contract and experiment-role permissions. RDS and Valkey targets now use deterministic resource tags with their required zonal parameters instead of invalid ARN-plus-parameter combinations, experiments fail closed when targets resolve empty, and the bootstrap role includes the permissions required by the configured EC2, network, RDS, and ElastiCache actions.

## Context

AWS first rejected CreateExperimentTemplate because RDSInstance combined resource ARNs with a filter. After that filter was removed and zonal parameters were added, the live API rejected RDSInstance again because AWS FIS also prohibits combining resource ARNs with parameters. The same selector family would be invalid for Valkey, whose availabilityZoneIdentifier parameter is required.

Constraints shaping the change:

- techx-corp-infra production uses AWS provider 5.100.0; the standalone module test lock currently uses 6.56.0.
- No Terraform apply or direct AWS mutation was run during this work.
- Bootstrap owns the pre-created FIS experiment role, so bootstrap must be deployed before the production composition.
- The original EC2 resource-tag plus filters selector is valid and remains unchanged.

## Before

- RDSInstance and ValkeyReplicationGroup temporarily combined explicit ARNs with AZ parameters; the live FIS API rejected that selector family for RDS, and Valkey requires its AZ parameter.
- ValkeyReplicationGroup used the supported resource type and action ID but omitted the required availabilityZoneIdentifier target parameter.
- Experiment empty-target behavior was implicit.
- The bootstrap role granted elasticache:TestFailover rather than the InterruptClusterAzPower operation used by the configured action.
- The role omitted tag:GetResources, required network-disruption discovery/tagging actions, and kms:CreateGrant for restarting instances with encrypted EBS volumes.
- The native module test checked output counts but not the rendered target definitions.

## After

- Each `primary-in` RDSInstance target uses its exact Name tag, has no ARN or filter, and sets `availabilityZoneIdentifiers` to the template AZ; both `primary-outside` variants omit the RDS target and failover action completely.
- Each ValkeyReplicationGroup target uses its exact Name tag, has no ARN, and sets the required availabilityZoneIdentifier to the template AZ.
- Experiment options explicitly use single-account targeting and fail when any required target resolves empty.
- The bootstrap role grants the exact ElastiCache mutation used by AWS FIS, separates discovery permissions onto wildcard resources, supports tag resolution and network ACL orchestration, and conditionally allows KMS grants for AWS resources.
- Native tests render all four variants through a mock provider and verify the conditional RDS and tag-plus-parameter target contracts.

## Technical Design Decisions

AWS FIS treats explicit resource ARNs as incompatible with filters and, as confirmed by the live CreateExperimentTemplate response, with resource parameters. RDS and Valkey therefore use their exact Terraform-managed Name tags plus the per-template AZ parameters. This follows the AWS AZ power-interruption scenario while avoiding broad environment-tag selection.

Fail mode was chosen for empty target resolution because these are resilience-control experiments: silently skipping a missing RDS, Valkey, EC2, or subnet target would produce misleading evidence. IAM changes follow the permissions listed for the selected actions and keep mutation permissions ARN-scoped where AWS supports it. Discovery-only actions remain Resource = * where service APIs do not provide useful resource-level scoping.

The production provider constraint was not upgraded. The standalone provider 6.56.0 test emits a deprecation warning for data.aws_region.current.name, while production provider 5.100.0 still uses that established attribute. Resolving that warning requires a separately reviewed provider-version alignment rather than mixing an upgrade into this FIS fix.

## Implementation Details

1. Added mock data for caller identity, partition, and Region to the native module test.
2. Added assertions that every rendered RDS and Valkey target has no resource ARNs, uses its exact Name tag, and retains the correct AZ parameter.
3. Added fail-closed single-account experiment options.
4. Replaced RDS and Valkey ARN selectors with deterministic Name-tag selectors while retaining availabilityZoneIdentifiers and availabilityZoneIdentifier.
5. Added EC2 prefix-list discovery and CreateTags permissions required by network disruption.
6. Replaced elasticache:TestFailover with elasticache:InterruptClusterAzPower and separated describe permissions.
7. Added tag:GetResources and a kms:GrantIsForAWSResource-conditioned kms:CreateGrant statement.
8. Ran formatting, validation, native tests, and static security scans without applying Terraform.

## Files Changed

**Bootstrap:**

- bootstrap/main.tf — Completed the FIS experiment-role permissions for all configured actions.

**Module:**

- modules/fis-az-failover/main.tf — Uses tag-plus-parameter selectors for zonal RDS and Valkey targets.
- modules/fis-az-failover/outputs.tf — Records the tag and AZ selectors without advertising unused ARN selector inputs.
- modules/fis-az-failover/tests/contract.tftest.hcl — Prevents ARN-plus-parameter regressions for rendered RDS and Valkey targets.
- modules/commerce-ha/main.tf — Adds the deterministic Name tag used to resolve the Valkey replication group.

**Documentation:**

- docs/plan/2026-07-28-fis-contract-hardening.md — Records the implementation and rollout sequence.
- docs/changes/2026-07-28-fix-fis-target-contracts.md — This change record.

## Dependencies and Cross-Repository Impact

None. The change is fully contained in techx-corp-infra. The bootstrap stack and production stack are separate Terraform roots inside this repository and must be deployed in that order.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No normal application runtime change; only FIS experiment behavior changes. |
| **Infrastructure** | Adds one Valkey Name tag and updates two FIS experiment templates after deployment. |
| **Deployment** | Requires a reviewed bootstrap plan/apply before the reviewed production plan/apply. |
| **Performance** | No steady-state impact. |
| **Security** | Adds only action-required permissions; KMS grant creation is conditioned to AWS resources. |
| **Reliability** | Prevents invalid templates and fails experiments when required targets resolve empty. |
| **Cost** | No steady-state resource cost; FIS experiment execution and logging retain their existing usage costs. |
| **Backward compatibility** | The production handoff now uses the required wrapper schemaVersion 1 shape; internal schema 2.0 identifies four variants, and moved blocks preserve the two existing inside-template Terraform identities. |
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
| Module lint | tflint --chdir=modules/fis-az-failover --format=compact | Existing three unused-input warnings; no selector errors |
| Commerce lint | tflint --chdir=modules/commerce-ha --format=compact | Existing three provider/version warnings; no tag errors |
| Checkov | checkov on both affected modules | Pass: zero failed checks; remote guideline metadata was unavailable through the configured proxy |
| Trivy | trivy config with HIGH,CRITICAL threshold | Pass: zero findings in FIS and commerce modules using embedded checks |
| Diff whitespace | git diff --check | Pass |

### Manual Verification

- Verified the new regression assertions failed before implementation because RDS and Valkey rendered ARNs and no resource tags.
- Verified the post-change plan-mode test renders exact Name tags, no ARN attributes, and us-east-1a/us-east-1b in the correct parameter keys.
- Compared action IDs, resource types, parameters, and permissions with current AWS FIS primary documentation.
- Live AWS CLI action inspection was unavailable because the local environment forces AWS traffic through an unreachable proxy.

### Remaining Verification (Post-Merge)

- Produce and review a saved bootstrap plan; operator approval required.
- Apply bootstrap, then produce and review the production plan; operator approval required.
- Generate skip-all target previews for all four templates; verify EC2, subnet, and Valkey targets in every preview and RDS only in the two `primary-in` templates. Query the current RDS primary again before selecting a live variant.
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
| A Name tag is missing or differs from the module identifier | Low | High | Terraform manages both tags from the same identifiers; fail-closed target resolution and target preview expose drift before fault execution. |
| Bootstrap permissions are not deployed before template execution | Medium | High | Enforce bootstrap-first rollout and inspect experiment AuthorizationFailure details. |
| Network disruption affects more tagged EC2 instances or subnets than intended | Low | High | Review explicit subnet ARNs and target preview; retain stop alarms and require execution approval. |
| Provider-version drift changes warnings or schema behavior | Low | Medium | Keep production on its locked provider for this change and handle provider alignment separately. |

**Rollback procedure:**

1. Revert this change in Git.
2. Generate and review a bootstrap plan that restores the prior inline policy; apply it only with explicit approval.
3. Generate and review a production plan that restores the prior experiment-template definitions; apply it only with explicit approval.
4. Do not start an experiment while rollback is in progress.

<!-- Change trail: @hungxqt - 2026-07-28 - Aligned selector documentation with the four-variant RDS contract. -->