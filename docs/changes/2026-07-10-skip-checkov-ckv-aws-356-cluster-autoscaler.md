# Change: Skip CKV_AWS_356 for Cluster Autoscaler IAM Policy

## Summary

Adds a Checkov skip comment for `CKV_AWS_356` on the Cluster Autoscaler IAM policy document. The policy intentionally uses `resources = ["*"]` for non-resource-level Describe APIs and for mutating ASG actions that are constrained by a resource-tag condition, matching the AWS-recommended Cluster Autoscaler IRSA pattern.

## Context

Checkov `CKV_AWS_356` failed on `module.cluster_autoscaler.aws_iam_policy_document.cluster_autoscaler` because both statements use `resources = ["*"]`. AWS does not support resource-level ARNs for the listed Describe APIs, and the official Cluster Autoscaler IAM guidance uses `*` with a tag condition for `SetDesiredCapacity` / `TerminateInstanceInAutoScalingGroup`. A documented skip is preferred over weakening the policy shape or globally suppressing the check.

## Before

* `modules/cluster-autoscaler/main.tf` IAM policy document had no Checkov skip.
* `checkov -d . --framework terraform` reported 1 failed check (`CKV_AWS_356`) on this resource.

## After

* A `# checkov:skip=CKV_AWS_356: ...` comment is present immediately above the policy document data source, with a justification for the intentional `*` resources.
* Checkov should treat this finding as skipped rather than failed for this resource.

## Technical Design Decisions

* **Inline skip vs global suppress:** Scoped skip on the single policy document avoids hiding other `CKV_AWS_356` findings elsewhere.
* **Keep `*` resources:** Changing mutate resources to ASG ARNs would break discovery for dynamically created/tagged ASGs; tag-based conditions are the supported least-privilege pattern for CA.
* **No policy behavior change:** Skip is documentation for the scanner only.

## Implementation Details

1. Added Checkov skip comment above `data.aws_iam_policy_document.cluster_autoscaler` in `modules/cluster-autoscaler/main.tf`.
2. Reason documents that Describe actions are not resource-level and mutate is limited by `autoscaling:ResourceTag/k8s.io/cluster-autoscaler/<cluster>` = `owned`.

## Files Changed

**Modules:**
* `modules/cluster-autoscaler/main.tf` — Added `# checkov:skip=CKV_AWS_356` with justification.

**Documentation:**
* `docs/changes/2026-07-10-skip-checkov-ckv-aws-356-cluster-autoscaler.md` — This change record.

## Dependencies and Cross-Repository Impact

None

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change |
| **Infrastructure** | No change to applied IAM policy content |
| **Deployment** | No deploy step required |
| **Security** | Scanner exception only; policy still uses tag-scoped mutate and read-only Describe list |
| **Backward compatibility** | Fully backward-compatible |
| **Observability** | Checkov failure count for this check reduced when skip is recognized |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Checkov skip syntax | Manual review of `# checkov:skip=CKV_AWS_356: ...` placement | Documented; re-run Checkov locally to confirm |

### Manual Verification

* Re-run: `checkov -d . --config-file .checkov.yaml --quiet --framework terraform --output sarif` from the infra root used in CI.
* Expect the previous `CKV_AWS_356` failure on this resource to be skipped (or absent from failed checks).

### Remaining Verification (Post-Merge)

* Confirm CI Checkov job no longer fails on `module.cluster_autoscaler.aws_iam_policy_document.cluster_autoscaler`.

## Migration or Deployment Notes

None

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Skip hides a future unsafe expansion of the same policy document | Low | Medium | Keep mutate tag condition; review any new actions carefully |
| Checkov version ignores the comment format | Low | Low | Align with project Checkov version skip syntax |

**Rollback procedure:**

1. Remove the `# checkov:skip=CKV_AWS_356: ...` line from `modules/cluster-autoscaler/main.tf`.
2. Re-run Checkov; the original failure will return.
