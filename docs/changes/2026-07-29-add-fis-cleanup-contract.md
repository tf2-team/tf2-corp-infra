# Change: Add FIS Cleanup Contract and EC2 Recovery Parameters

## Summary

This change updates the Mandate 21 AWS FIS experiment templates and Terraform output contracts in `techx-corp-infra`. It configures FIS native recovery parameters (`startInstancesAfterDuration = "PT10M"` and `completeIfInstancesTerminated = "true"`) on `StopEC2Instances`, attaches tag `CleanupPolicy = "fis-native-verify-v1"`, and exposes a static `cleanup` policy object per template and an additive `cleanupByTemplateId` map in `mandate21_fis_contract`.

## Context

FIS experiments require deterministic, fail-closed cleanup verification across all four FIS template variants (`1a-primary-in`, `1a-primary-outside`, `1b-primary-in`, `1b-primary-outside`). Adding `completeIfInstancesTerminated = "true"` allows FIS post-actions to complete successfully when EKS or Karpenter replaces stopped target nodes rather than restarting the original instance IDs. Publishing the static cleanup policy enables runtime drill wrappers to perform fail-closed verification without mutating infrastructure.

## Before

* `StopEC2Instances` action configured `startInstancesAfterDuration = "PT10M"` but omitted `completeIfInstancesTerminated`.
* FIS experiment templates did not expose a `CleanupPolicy` tag.
* `module.fis_az_failover` output `contract.templates[variant]` contained target selectors and fault durations but no static `cleanup` verification policy object.
* `environments/production` output `mandate21_fis_contract` contained `schemaVersion`, `region`, `clusterContext`, `namespace`, `storefrontUrl`, `rdsInstanceIdentifier`, and `zones`, but no `cleanupByTemplateId` map.

## After

* All four `StopEC2Instances` actions configure both `startInstancesAfterDuration = "PT10M"` and `completeIfInstancesTerminated = "true"`.
* All four FIS templates expose tag `CleanupPolicy = "fis-native-verify-v1"`.
* Every template entry in `module.fis_az_failover` output `contract.templates[variant]` contains a `cleanup` policy object with `policyVersion = 1`, `mode = "verify-only"`, `timeoutMinutes = 45`, `pollIntervalSeconds = 15`, `requiredAlarmWindows = 2`, and an `expected` block. `rdsFailoverExpected` is set to `true` for primary-in variants and `false` for primary-outside variants.
* `mandate21_fis_contract` in production includes `cleanupByTemplateId` mapping every active template ID to its cleanup verification policy.

## Technical Design Decisions

* **Native FIS Recovery**: Relies strictly on AWS FIS native post-actions and auto-restart capabilities. No automatic remediation scripts or broad IAM permissions are introduced.
* **Additive Output Contract**: Maintained `schemaVersion = 1` and existing `zones` structure to ensure full backward compatibility with existing Person 3 wrapper consumers while exposing `cleanupByTemplateId`.

## Implementation Details

1. Added `completeIfInstancesTerminated = "true"` parameter to `StopEC2Instances` action in `modules/fis-az-failover/main.tf`.
2. Added `CleanupPolicy = "fis-native-verify-v1"` tag to `aws_fis_experiment_template.az_failover` in `modules/fis-az-failover/main.tf`.
3. Extended `contract.templates[variant]` in `modules/fis-az-failover/outputs.tf` to expose `cleanup` policy object.
4. Added `cleanupByTemplateId` field to `mandate21_fis_contract` output in `environments/production/outputs.tf`.
5. Updated Terraform test assertions in `modules/fis-az-failover/tests/contract.tftest.hcl` and `environments/production/tests/mandate21_fis.tftest.hcl` to validate all cleanup contract fields and parameters.

## Files Changed

**Configuration:**
* `modules/fis-az-failover/main.tf` — Added `completeIfInstancesTerminated` parameter and `CleanupPolicy` tag to FIS experiment templates.
* `modules/fis-az-failover/outputs.tf` — Exposed static `cleanup` policy object in contract template map.
* `environments/production/outputs.tf` — Added additive `cleanupByTemplateId` map to `mandate21_fis_contract`.

**Tests:**
* `modules/fis-az-failover/tests/contract.tftest.hcl` — Asserted EC2 recovery parameters, `CleanupPolicy` tag, and template cleanup contract.
* `environments/production/tests/mandate21_fis.tftest.hcl` — Asserted `cleanupByTemplateId` schema and policy contents in production output.

**Documentation:**
* `docs/changes/2026-07-29-add-fis-cleanup-contract.md` — This change document.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-chart/docs/changes/2026-07-29-add-fis-cleanup-state-verification.md`
* The PowerShell drill wrapper in `techx-corp-chart` consumes `cleanupByTemplateId` from `mandate21_fis_contract`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change to running application workloads. |
| **Infrastructure** | In-place update to four AWS FIS experiment templates (`completeIfInstancesTerminated` and tag). Zero resource creation or destruction. |
| **Deployment** | Requires `terraform apply` on production infrastructure environment. |
| **Performance** | No performance impact. |
| **Security** | Zero IAM changes; existing `ec2:DescribeInstances` permission is sufficient. |
| **Reliability** | Ensures FIS post-actions complete cleanly when Karpenter/EKS replaces stopped nodes. |
| **Cost** | Zero additional cost. |
| **Backward compatibility** | Fully backward-compatible; additive contract fields preserve schemaVersion 1 consumers. |
| **Observability** | Adds static cleanup verification attributes to output contract evidence. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Module Format | `terraform fmt -check` (modules/fis-az-failover) | ✅ Pass |
| Module Validate | `terraform validate` (modules/fis-az-failover) | ✅ Pass |
| Module Tests | `terraform test -no-color` (modules/fis-az-failover) | ✅ Pass |
| Environment Format | `terraform fmt -check` (environments/production) | ✅ Pass |
| Environment Validate | `terraform validate` (environments/production) | ✅ Pass |
| Environment Tests | `terraform test -filter=tests/mandate21_fis.tftest.hcl -no-color` | ✅ Pass |

### Manual Verification

* Generated production plan (`mandate21-cleanup.tfplan`) confirming 4 in-place FIS template updates and output contract changes only.

### Remaining Verification (Post-Merge)

* Apply reviewed production plan and refresh `mandate21-fis-contract.json` in `techx-corp-chart`.

## Migration or Deployment Notes

1. Run `terraform plan -out=mandate21-cleanup.tfplan` in `environments/production` and confirm exactly 4 in-place updates.
2. Apply the reviewed plan.
3. Update `techx-corp-chart/scripts/mandate21-fis-contract.json` using `terraform output -json mandate21_fis_contract`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| FIS template schema error during apply | Low | Low | Validated via `terraform test` mock execution. Roll back by reverting template main.tf and outputs.tf. |

**Rollback procedure:**

1. Revert Terraform changes in `modules/fis-az-failover` and `environments/production`.
2. Generate a new Terraform plan and apply to remove `completeIfInstancesTerminated` parameter and `CleanupPolicy` tag.

<!-- Change trail: @hungxqt - 2026-07-29 - Documented FIS cleanup contract and EC2 recovery parameter changes. -->
