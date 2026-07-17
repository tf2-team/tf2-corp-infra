# Change: Karpenter consolidateAfter 0s for immediate empty reclaim

## Summary

Set NodePool `consolidateAfter` to `0s` in development and production so empty nodes — including those with only DaemonSet pods such as the otel-collector agent — consolidate immediately instead of waiting for a multi-minute settle delay.

## Context

After application pods leave a Karpenter node, system DaemonSets (otel-collector agent, aws-node, kube-proxy, ebs-csi-node, and similar) often remain. Karpenter already treats DaemonSet-only nodes as **empty**, but `consolidateAfter: 5m` still delayed reclaim. Operators want agent-only / empty nodes reclaimed without that wait.

* Why now: avoid paying for nodes that only host the otel agent (and other DaemonSets) after scale-in.
* Constraint: Karpenter exposes a single `consolidateAfter` for both empty and underutilized consolidation under `WhenEmptyOrUnderutilized`; there is no separate “empty only” delay knob in v1.13.

## Before

* Development and production tfvars: `karpenter_consolidate_after = "5m"`.
* Module / chart defaults: `1m`.
* Empty (DaemonSet-only) and underutilized nodes waited five minutes of pod stability before consolidation eligibility.

## After

* Development and production tfvars: `karpenter_consolidate_after = "0s"`.
* Module variable and node-resources chart default: `0s`.
* Policy remains `WhenEmptyOrUnderutilized` with disruption budgets `"1"`/`"1"`.
* DaemonSet-only nodes (otel agent only from an application perspective) become consolidation candidates immediately after the last non-DaemonSet pod leaves (subject to budgets and PDBs).

## Technical Design Decisions

* **Use `0s` rather than a short positive delay** so empty reclaim matches the “immediately” requirement.
* **Keep `WhenEmptyOrUnderutilized`** so underutilized packing still runs; the trade-off is that underutilized consolidation is also eligible at `0s` (no 5-minute settle). Raise `karpenter_consolidate_after` if underutilized churn is noisy.
* **No chart change to the otel DaemonSet** — mode is already `daemonset`; DaemonSets have zero disruption cost and do not block empty classification.
* **Rejected** treating otel specially with annotations: unnecessary for a DaemonSet, and would not remove the shared `consolidateAfter` delay.

## Implementation Details

1. Set `karpenter_consolidate_after = "0s"` in development and production `terraform.tfvars` with comments describing DaemonSet-only empty behavior.
2. Default env variables and module `consolidate_after` to `0s`.
3. Default `modules/karpenter/charts/node-resources/values.yaml` `consolidateAfter` to `0s`.
4. Update `docs/karpenter.md` and `docs/workload-placement.md` for the new contract.

## Files Changed

**Configuration:**
* `environments/development/terraform.tfvars` — `karpenter_consolidate_after` → `0s`.
* `environments/production/terraform.tfvars` — `karpenter_consolidate_after` → `0s`.
* `environments/development/variables.tf` — default/description for `karpenter_consolidate_after`.
* `environments/production/variables.tf` — default/description for `karpenter_consolidate_after`.
* `modules/karpenter/variables.tf` — `consolidate_after` default `0s`.
* `modules/karpenter/charts/node-resources/values.yaml` — chart default `0s`.

**Documentation:**
* `docs/karpenter.md` — config table and runbook for `0s` / empty DaemonSet reclaim.
* `docs/workload-placement.md` — lifecycle and disruption narrative.
* `docs/changes/2026-07-15-karpenter-consolidate-after-0s.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related chart runbook: `techx-corp-chart/docs/changes/2026-07-15-karpenter-consolidate-after-0s.md`.
* Live effect requires approved Terraform apply per environment (NodePool CRs).
* Otel collector remains a DaemonSet in `techx-corp-chart` (`mode: daemonset`); no platform change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No API change; app pods on underutilized nodes may drain sooner after scale-in because underutilized also uses `0s` |
| **Infrastructure** | Empty NodeClaims terminate sooner after last non-DaemonSet pod exits |
| **Deployment** | Approved Terraform apply for development and/or production |
| **Performance** | Faster reclaim of idle capacity after scale-in |
| **Reliability** | Slightly higher consolidation churn if load flaps rapidly; budgets still cap concurrent voluntary disruptions |
| **Cost** | Lower cost when nodes would otherwise sit DaemonSet-only for minutes |
| **Backward compatibility** | Config-only; fully compatible with existing workloads |
| **Observability** | Expect earlier NodeClaim/node drops after empty; otel agent terminates with the node as any DaemonSet does |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Config review | Grep of `karpenter_consolidate_after` in env tfvars | ✅ `"0s"` in development and production |
| Default review | Module + chart defaults | ✅ `0s` |

### Manual Verification

* Confirmed otel collector is configured as a DaemonSet in the chart (`mode: daemonset`), so agent-only application occupancy classifies as empty.

### Remaining Verification (Post-Merge)

1. Approved Terraform plan/apply per environment.
2. `kubectl get nodepool -o yaml` → `spec.disruption.consolidateAfter: 0s`.
3. Scale a workload to zero and confirm a Karpenter node that retains only DaemonSets (including otel-collector) becomes eligible for consolidation without a multi-minute wait (still subject to budgets `"1"`).

## Migration or Deployment Notes

1. Merge this infra change.
2. Apply with explicit approval:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/development plan -out=tfplan
REM Review plan; apply only with explicit approval
terraform -chdir=environments/development apply tfplan

terraform -chdir=environments/production plan -out=tfplan
REM Review plan; apply only with explicit approval
terraform -chdir=environments/production apply tfplan
```

3. Confirm NodePools show `consolidateAfter: 0s`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Underutilized packing churn under flapping load | Medium | Low | Raise `karpenter_consolidate_after` (e.g. `1m` or `5m`); note empty reclaim will delay by the same amount |
| Too many concurrent consolidations | Low | Medium | Budgets remain `"1"`/`"1"`; freeze to `"0"` if needed |

**Rollback procedure:**

1. Set `karpenter_consolidate_after` back to a positive duration (e.g. `"5m"`) in the target env tfvars.
2. Review Terraform plan and apply with explicit approval.
3. Confirm NodePools show the restored `consolidateAfter`.

<!-- Change trail: @hungxqt - 2026-07-15 - Record Karpenter consolidateAfter 0s for immediate empty reclaim. -->
