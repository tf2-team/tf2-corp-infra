# Change: Fix Checkov CKV_AWS_79 (IMDSv2) and CKV_AWS_356 (CA IAM)

## Summary

Resolved two Checkov Terraform failures: require IMDSv2 on EKS managed node group launch templates (`CKV_AWS_79`), and tighten Cluster Autoscaler IAM mutate permissions to ASG ARN patterns while correctly suppressing the remaining Describe `*` requirement (`CKV_AWS_356`). Restored committed `.checkov.yaml` with the project’s intentional global skips.

## Context

CI/local Checkov reported:

* `CKV_AWS_79` on `module.eks.aws_launch_template.node` — no `metadata_options` (IMDSv1 allowed by default).
* `CKV_AWS_356` on `module.cluster_autoscaler.aws_iam_policy_document.cluster_autoscaler` — mutate statement used `resources = ["*"]`; prior skip comment above the data source was not recognized by Checkov.

## Before

* Launch template set disk size + NodeConfig maxPods only; instance metadata defaulted to optional tokens (IMDSv1 usable).
* CA IAM mutate actions used `resources = ["*"]` with a tag condition only.
* Skip comment sat *above* the data block and did not suppress the finding.
* `.checkov.yaml` was missing from the repo root (user run referenced it).

## After

* Launch template requires IMDSv2 (`http_tokens = required`), hop limit 1, metadata tags disabled.
* CA mutate actions limited to  
  `arn:<partition>:autoscaling:<region>:<account>:autoScalingGroup:*:autoScalingGroupName/*`  
  plus the existing cluster ownership tag condition.
* Describe/GetInstanceTypes statement still uses `resources = ["*"]` (AWS non-resource-level APIs) with an **in-block** `# checkov:skip=CKV_AWS_356` justification.
* `.checkov.yaml` restored with the documented skip list (ECR/EKS/VPC/S3/KMS/Secrets).

## Technical Design Decisions

* **IMDSv2 required + hop_limit 1:** Blocks IMDSv1 and pod SSRF to the host IMDS path; IRSA does not need IMDS.
* **ASG ARN pattern for mutate (not global skip only):** Real least-privilege improvement; tag condition still required so CA only scales owned ASGs.
* **Scoped skip for Describe *:** Prefer inline suppress over global `skip-check: CKV_AWS_356` so other IAM docs still fail closed.
* **Skip inside data block:** Checkov attaches suppressions when the comment is inside the scanned block.

## Implementation Details

1. Added `metadata_options` to `modules/eks` `aws_launch_template.node`.
2. Added `aws_caller_identity` / `aws_partition` data sources in cluster-autoscaler module; scoped mutate resources.
3. Moved Checkov skip into the policy document data block.
4. Added `.checkov.yaml` with existing project skip list.

## Files Changed

**Modules:**

* `modules/eks/main.tf` — IMDSv2 metadata options on node launch template.
* `modules/cluster-autoscaler/main.tf` — ASG ARN-scoped mutate; in-block CKV_AWS_356 skip for Describe.

**Config / docs:**

* `.checkov.yaml` — Framework + intentional skip-check list.
* `docs/changes/2026-07-10-fix-checkov-imdsv2-and-ca-iam.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart/platform unchanged. Node group launch template version will roll when applied (new LT version for maxPods-enabled groups).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No intentional app change; pods cannot use IMDSv1 via host hop |
| **Infrastructure** | MNG launch template version bump on apply; CA IAM policy JSON tighter if CA enabled |
| **Security** | IMDSv2 required; CA mutate no longer unrestricted `*` |
| **Deployment** | Terraform apply for EKS module; existing nodes pick up IMDS settings on recycle/replace |
| **Backward compatibility** | Workloads relying on IMDSv1 or hop>1 IMDS from pods may break (none expected with IRSA) |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| CKV_AWS_79 | `checkov -d modules/eks --check CKV_AWS_79` | ✅ PASSED |
| CKV_AWS_356 | `checkov -d modules/cluster-autoscaler --check CKV_AWS_356` | ✅ SKIPPED (justified) |
| Terraform validate | `terraform validate` (development) | ✅ Pass |

### Manual Verification

* Confirmed suppress comment appears in Checkov “SKIPPED” output for the CA policy document.

### Remaining Verification (Post-Merge)

```bash
cd techx-corp-infra
checkov -d . --config-file .checkov.yaml --quiet --framework terraform --output sarif
```

Expect **no** failed `CKV_AWS_79` / `CKV_AWS_356` on these resources.

## Migration or Deployment Notes

1. Apply Terraform for environments using maxPods launch templates (dev/prod with `max_pods` set).
2. Rolling node replacement (or next MNG update) applies IMDSv2 to workers.
3. If Cluster Autoscaler is enabled, re-apply so IAM policy attaches the tighter mutate statement.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Node software expecting IMDSv1 | Low | Medium | Revert metadata_options or set http_tokens=optional temporarily |
| CA cannot scale if ASG ARN region mismatch | Low | Medium | Region from `var.aws_region`; verify role policy after apply |

**Rollback procedure:**

1. Remove `metadata_options` block or set `http_tokens = "optional"`.
2. Restore mutate `resources = ["*"]` if CA breaks (tag condition remains).
3. Re-apply Terraform.
