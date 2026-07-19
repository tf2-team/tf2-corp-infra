# Change: Open Karpenter Disruption Budgets in Development

## Summary

Opened development Karpenter NodePool voluntary disruption budgets from migration freeze `"0"`/`"0"` to steady-state `"1"`/`"1"` per pool, and made `consolidateAfter` an explicit development input set to `1m` so `WhenEmptyOrUnderutilized` consolidation can reclaim idle capacity shortly after load drops.

## Context

Migration and placement work froze per-NodePool disruption budgets at `"0"`, which blocks voluntary disruption including consolidation. That left underutilized Karpenter nodes running even when pods could pack onto fewer nodes. Development is past the freeze for this knob; production remains frozen until placement install/acceptance.

* Why now: reduce excess Karpenter node count by allowing consolidation.
* Related: `docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md`, `docs/karpenter.md`.

## Before

* Development `karpenter_disruption_budget_nodes = { spot = "0", on_demand = "0" }` (migration freeze).
* Environment default for disruption budgets was `"0"`/`"0"`.
* `consolidate_after` existed only on the Karpenter module (default `1m`); development did not expose or pin it in tfvars.
* Docs described development budgets as migration freeze.

## After

* Development budgets: `spot = "1"`, `on_demand = "1"` (one voluntary disruption **per NodePool**).
* Development `karpenter_consolidate_after = "1m"` wired into the Karpenter module.
* Environment variable default for budgets is steady-state `"1"`/`"1"`; freeze remains documented for upgrades.
* Production tfvars unchanged (`"0"`/`"0"`, install flags still off).
* Docs (`karpenter.md`, `workload-placement.md`) reflect development steady-state consolidation.

## Technical Design Decisions

* **Open both pools to `"1"`** rather than Spot-only: both Spot and On-Demand NodePools use the same consolidation policy; leaving OD at `"0"` would strand underutilized On-Demand fallback nodes.
* **Keep `consolidateAfter` at `1m`** in development (within 1–5m guidance) for fast reclaim; operators can raise via `karpenter_consolidate_after` if churn is noisy.
* **Do not change production** in this change: Helm/NodePools are still disabled and placement freeze remains intentional.
* **Budgets are per NodePool**, not a single cluster-wide “one node” limit (documented previously).

## Implementation Details

1. Set development tfvars disruption budgets to `"1"`/`"1"` and document freeze-only-during-upgrades.
2. Added `karpenter_consolidate_after` variable (default `1m`) and passed `consolidate_after` into `module.karpenter`.
3. Updated development variable default for budgets to steady-state `"1"`/`"1"`.
4. Updated operational docs and this change record.

No NodePool template changes: charts already render `consolidationPolicy: WhenEmptyOrUnderutilized`, `consolidateAfter`, and per-pool budgets from Helm values.

## Files Changed

**Configuration:**

* `environments/development/terraform.tfvars` — budgets `"1"`/`"1"`; `karpenter_consolidate_after = "1m"`.
* `environments/development/variables.tf` — budget default steady-state; new `karpenter_consolidate_after`.
* `environments/development/main.tf` — pass `consolidate_after` into Karpenter module.

**Documentation:**

* `docs/karpenter.md` — config table, scale-test note, consolidation runbook.
* `docs/workload-placement.md` — status, NodePool budget table, consolidateAfter note.
* `docs/changes/2026-07-11-open-karpenter-disruption-budgets-dev.md` — this change record.

## Dependencies and Cross-Repository Impact

None. Chart placement and NodePool CR shapes are unchanged. Applies only when development Terraform is applied with `karpenter_create_node_resources = true` (already true in dev).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No pod API change; pods may be rescheduled during consolidation drains |
| **Infrastructure** | Karpenter may terminate empty/underutilized nodes after ~1m when budget allows |
| **Deployment** | Requires Terraform apply in development to update NodePool CRs via node-resources Helm |
| **Performance** | Fewer idle nodes after scale-down; brief reschedule cost during consolidation |
| **Reliability** | Up to one voluntary disruption per pool at a time; freeze again for risky upgrades |
| **Cost** | Expected reduction when idle Karpenter capacity is reclaimed |
| **Backward compatibility** | Fully compatible; reversible by setting budgets back to `"0"` |
| **Observability** | Watch NodeClaims/nodes drop after load removal; controller consolidation logs |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Config review | Diff of tfvars/variables/main against module inputs | ✅ Module already accepts `consolidate_after` and `disruption_budget_nodes` |
| Terraform plan | `terraform -chdir=environments/development plan` | Operator post-merge (needs cluster credentials) |

### Manual Verification

* After apply:

```bash
kubectl get nodepool stateless-spot stateless-on-demand -o yaml
# Expect: disruption.budgets nodes "1"; consolidateAfter "1m"; consolidationPolicy WhenEmptyOrUnderutilized
```

* Scale-test cleanup: delete load → underutilized Karpenter nodes should consolidate after ~1m (subject to PDBs).

### Remaining Verification (Post-Merge)

1. `terraform -chdir=environments/development plan` then apply when ready.
2. Confirm NodePool CRs show budgets `"1"` and `consolidateAfter: 1m`.
3. Optional: run scale-test from `docs/karpenter.md` and observe reclaim.

## Migration or Deployment Notes

1. Ensure cluster API is reachable (dev already installs Karpenter Helm + node resources).
2. Apply development Terraform; node-resources Helm release updates NodePools in place.
3. No chart or application redeploy required.
4. To re-freeze (e.g. before a multi-minor Karpenter upgrade): set budgets to `"0"`/`"0"`, apply, upgrade, then reopen.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Consolidation drains cause brief pod restarts | Medium | Low | PDBs already on multi-replica HPA services; budget caps concurrent voluntary disruption |
| Over-aggressive reclaim under flapping load | Low | Low | Raise `karpenter_consolidate_after` (e.g. `5m`) |
| Unexpected concurrent disruption on both pools | Low | Medium | Budgets are independent; freeze either pool to `"0"` if needed |

**Rollback procedure:**

1. In `environments/development/terraform.tfvars` set:

```hcl
karpenter_disruption_budget_nodes = {
  spot      = "0"
  on_demand = "0"
}
```

2. `terraform -chdir=environments/development apply`
3. Optional: increase `karpenter_consolidate_after` instead of full freeze if only churn is the issue.
