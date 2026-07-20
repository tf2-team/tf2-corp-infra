# Change: Enable EKS Control Plane CloudWatch Logs

## Summary

Completes EKS control-plane logging in Terraform by managing the CloudWatch log group with explicit retention, making log types configurable, and wiring both development and production stacks (api/audit/authenticator; dev 7-day retention, prod 30-day).

## Context

EKS control-plane log types (`api`, `audit`, `authenticator`) were already set on `aws_eks_cluster` (PR #59), but the log group was not managed in Terraform. When AWS creates `/aws/eks/<cluster>/cluster` automatically, retention defaults to **Never expire**, which grows cost without operator control. This change closes that gap and documents the cost posture (three log types, not all five).

* Needed now for auditability (API/auth/audit trails) and FinOps control over log retention.
* Related prior work: `feat(eks): enable control plane logging` (#59).
* Constraint: keep Checkov `CKV_AWS_37` skipped — full five types (including `scheduler` / `controllerManager`) increase ingest cost; defaults stay security-focused.

## Before

* `modules/eks/main.tf` hardcoded `enabled_cluster_log_types = ["api", "audit", "authenticator"]`.
* No `aws_cloudwatch_log_group` for the control-plane log group.
* No env-level knobs for log types or retention.
* `docs/COST.md` stated control-plane logging was not enabled by default.

## After

* Module creates `/aws/eks/<cluster_name>/cluster` **before** the cluster (when log types are non-empty) with `retention_in_days`.
* Log types and retention are module variables, passed from both environment stacks.
* Defaults: log types `api`/`audit`/`authenticator`; retention **7 days** (dev) / **30 days** (prod).
* Outputs expose `cluster_log_group_name` and `enabled_cluster_log_types`.
* `docs/COST.md` reflects enabled control-plane logging and retention.

## Technical Design Decisions

* **Three log types by default (not five):** Matches existing security-focused enablement and Checkov cost skip for `CKV_AWS_37`. Operators can set `enabled_cluster_log_types` to include `scheduler` and/or `controllerManager` without a module code change.
* **Managed log group before cluster:** Ensures retention is set on first enable; avoids Never-expire AWS auto-created groups.
* **No CMK on the log group:** Same cost posture as Client VPN connection logs (`CKV_AWS_158` skip with justification).
* **Empty list disables logging:** `count` on the log group + empty `enabled_cluster_log_types` turns control-plane logging off cleanly.

Alternatives considered:

| Approach | Rejected because |
|---|---|
| Enable all five types always | Higher CloudWatch ingest cost; project intentionally limited types |
| Leave AWS auto-created log group | No retention control; Never expire |
| Per-type log groups | EKS always writes to a single `/aws/eks/<name>/cluster` group |

## Implementation Details

1. Added `aws_cloudwatch_log_group.cluster` in `modules/eks` with path `/aws/eks/${var.cluster_name}/cluster`.
2. Added variables `enabled_cluster_log_types` and `cluster_log_retention_days` (validated AWS retention values).
3. Wired `enabled_cluster_log_types` on `aws_eks_cluster` and `depends_on` the log group.
4. Exposed module/env outputs for log group name and enabled types.
5. Set tfvars: dev retention 7, prod retention 30; same three log types in both envs.
6. Updated `docs/COST.md` and Checkov skip comment for accuracy.

## Files Changed

**Module:**
* `modules/eks/main.tf` — CloudWatch log group + cluster depends_on + variable-driven log types.
* `modules/eks/variables.tf` — `enabled_cluster_log_types`, `cluster_log_retention_days`.
* `modules/eks/outputs.tf` — `cluster_log_group_name`, `enabled_cluster_log_types`.

**Environments:**
* `environments/development/main.tf` — Pass logging variables into `module.eks`.
* `environments/development/variables.tf` — Env variables (default retention 7).
* `environments/development/terraform.tfvars` — Explicit log types and retention.
* `environments/development/outputs.tf` — Export log group / types.
* `environments/production/main.tf` — Pass logging variables into `module.eks`.
* `environments/production/variables.tf` — Env variables (default retention 30).
* `environments/production/terraform.tfvars` — Explicit log types and retention.
* `environments/production/outputs.tf` — Export log group / types.

**Docs / config:**
* `docs/COST.md` — Control-plane logging cost note.
* `.checkov.yaml` — Clarify CKV_AWS_37 skip rationale.
* `docs/changes/2026-07-20-enable-eks-control-plane-logs.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart and platform repositories are unchanged. No image or Helm contract impact.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime app change; control-plane logs land in CloudWatch when applied |
| **Infrastructure** | Creates/manages one CloudWatch log group per cluster; enables EKS log types on the cluster |
| **Deployment** | Normal Terraform plan/apply for each environment stack |
| **Performance** | Negligible control-plane overhead |
| **Security** | Improves audit trail (API/audit/authenticator) |
| **Reliability** | Better post-incident diagnosis for auth and API issues |
| **Cost** | CloudWatch ingest + storage for three log streams; retention caps storage (7d/30d) |
| **Backward compatibility** | Fully compatible; empty log-type list can disable |
| **Observability** | Control-plane logs available under `/aws/eks/<cluster>/cluster` |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt modules/eks environments/development environments/production` | ✅ Pass |
| Validate (dev) | `terraform -chdir=environments/development init -backend=false` then `validate` | ✅ Pass |
| Validate (prod) | `terraform -chdir=environments/production init -backend=false` then `validate` | ✅ Pass |

### Manual Verification

* Code review of module dependency order (log group before cluster).
* Confirmed retention values are in the AWS-allowed set.

### Remaining Verification (Post-Merge)

1. Plan/apply **development**, then **production** (or via existing Terraform CI).
2. Confirm:

```cmd
aws eks describe-cluster --name techx-dev --query "cluster.logging" --output json
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/techx-dev" --output table
aws eks describe-cluster --name techx-tf2-prod --query "cluster.logging" --output json
aws logs describe-log-groups --log-group-name-prefix "/aws/eks/techx-tf2-prod" --output table
```

3. In CloudWatch Logs, open streams under `/aws/eks/<cluster>/cluster` after cluster API activity.

## Migration or Deployment Notes

1. **If the log group already exists** (AWS auto-created when logging was first enabled), import it before apply:

```cmd
cd /d techx-corp-infra\environments\development
terraform import "module.eks.aws_cloudwatch_log_group.cluster[0]" /aws/eks/techx-dev/cluster
```

```cmd
cd /d techx-corp-infra\environments\production
terraform import "module.eks.aws_cloudwatch_log_group.cluster[0]" /aws/eks/techx-tf2-prod/cluster
```

2. Apply the environment stack as usual (`terraform plan` → review → `terraform apply`).
3. No chart or platform deploy required.
4. To add `scheduler` / `controllerManager` later, set in tfvars:

```hcl
enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Import required for pre-existing log group | Medium | Low | Documented import; apply fails closed until import |
| CloudWatch ingest cost higher than expected | Low | Low | Three types + retention; can drop types via tfvars |
| Retention change deletes old log events | Low | Medium | Prod uses 30 days; raise retention before apply if longer history is required |

**Rollback procedure:**

1. Set `enabled_cluster_log_types = []` in the env tfvars (disables logging) **or** revert this commit.
2. Plan/apply the environment.
3. Optionally delete the log group only if logs must be purged (not required for disable).

<!-- Change trail: @hungxqt - 2026-07-20 - Record EKS control plane CloudWatch logging enablement. -->
