# Change: Production Karpenter consolidateAfter to 5m

## Summary

Production Karpenter NodePool `consolidateAfter` was reduced from `10m` to `5m` so empty/underutilized nodes reclaim on the same delay as development.

## Context

Operators wanted a shorter production consolidation window. Development already uses `5m`; production used `10m` after the harden-karpenter-scaling change. Aligning both environments simplifies runbooks and speeds idle-capacity reclaim after scale-in, while disruption budgets (`"1"`/`"1"`) and PDBs still bound voluntary disruption.

* Why now: operator request to match development reclaim timing.
* Constraints: change is tfvars-only; NodePool templates already render `consolidateAfter` from module input; apply still requires explicit Terraform approval.

## Before

* `environments/production/terraform.tfvars`: `karpenter_consolidate_after = "10m"`.
* Docs (`docs/karpenter.md`, `docs/workload-placement.md`) documented development `5m` and production `10m`.

## After

* `environments/production/terraform.tfvars`: `karpenter_consolidate_after = "5m"`.
* Operational docs state `5m` for both development and production.
* Variable default in `variables.tf` remains `1m` (module fallback); live intent is still set by tfvars.

## Technical Design Decisions

* **Align to development `5m`** rather than an intermediate value: same operator expectation in both clusters; still longer than the historical `1m` default that caused noisy churn.
* **No change to disruption budgets or consolidation policy** (`WhenEmptyOrUnderutilized`, budgets `"1"`/`"1"`): only the wait before reclaim changes.
* **Rejected keeping `10m`**: slower reclaim after load drops with no additional safety beyond existing budgets/PDBs for this environment’s current policy.

## Implementation Details

1. Set `karpenter_consolidate_after = "5m"` in production `terraform.tfvars`.
2. Updated `docs/karpenter.md` and `docs/workload-placement.md` tables/runbook text to `5m` for production.
3. No module template changes; Helm NodePool values already pass `consolidate_after` through.

## Files Changed

**Configuration:**
* `environments/production/terraform.tfvars` — Production `karpenter_consolidate_after` `10m` → `5m`.

**Documentation:**
* `docs/karpenter.md` — Config table, scale-test note, and consolidation runbook now say production `5m`.
* `docs/workload-placement.md` — Lifecycle and disruption narrative updated to `5m` for production.
* `docs/changes/2026-07-15-prod-karpenter-consolidate-after-5m.md` — This change record.

## Dependencies and Cross-Repository Impact

* Related chart runbook update: `techx-corp-chart/docs/changes/2026-07-15-prod-karpenter-consolidate-after-5m.md` (validation wait text only).
* Takes effect on production only after an approved `terraform apply` for `environments/production` that updates the NodePool Helm values / CRs.
* No platform application change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No API change; pods on consolidating nodes may drain/reschedule ~5 minutes earlier after underutilization than with `10m` |
| **Infrastructure** | Karpenter may terminate empty/underutilized NodeClaims sooner after scale-in |
| **Deployment** | Requires approved Terraform apply of production env (NodePool `consolidateAfter`) |
| **Performance** | Faster reclaim of idle capacity; brief reschedule cost during consolidation unchanged in kind |
| **Reliability** | Slightly higher chance of consolidation during load flap within a 5–10 minute window; budgets still cap concurrent voluntary drains |
| **Cost** | Expected modest savings when capacity sits idle 5–10 minutes after scale-in |
| **Backward compatibility** | Fully backward-compatible for workloads; config value change only |
| **Observability** | Expect consolidation-related NodeClaim/node drops after ~5m idle rather than ~10m |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Config review | Grep/diff of `karpenter_consolidate_after` in production tfvars | ✅ Set to `"5m"` |
| Doc consistency | Grep of production consolidateAfter narrative in `docs/karpenter.md` and `docs/workload-placement.md` | ✅ `5m` for both envs |

### Manual Verification

* Confirmed only production tfvars value and docs were intended to change; development remains `5m`.

### Remaining Verification (Post-Merge)

1. Review and approve production Terraform plan (expect NodePool `consolidateAfter` update).
2. After apply: `kubectl get nodepool -o yaml` (or equivalent) and confirm `spec.disruption.consolidateAfter: 5m` on both pools.
3. Optional: scale-in test — idle nodes should become eligible after ~5m, subject to PDBs and budgets.

## Migration or Deployment Notes

1. Merge this infra change.
2. From an approved operator session:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
REM Review plan; apply only with explicit approval
terraform -chdir=environments/production apply tfplan
```

3. Confirm NodePools show `consolidateAfter: 5m`.
4. No chart image or application redeploy required for this setting.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Consolidation during brief load dips | Low–Medium | Low | Raise `karpenter_consolidate_after` again (e.g. `10m`) via tfvars; freeze budgets to `"0"` if needed during incident |
| Unexpected pod churn | Low | Medium | PDBs and disruption budgets remain; freeze budgets if consolidation must stop immediately |

**Rollback procedure:**

1. Set `karpenter_consolidate_after = "10m"` in `environments/production/terraform.tfvars`.
2. Review Terraform plan and apply with explicit approval.
3. Confirm NodePools show `consolidateAfter: 10m`.

<!-- Change trail: @hungxqt - 2026-07-15 - Record production Karpenter consolidateAfter change to 5m. -->
