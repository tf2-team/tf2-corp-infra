# Change: Implement Workload Placement Phase 1 (Critical MNG vs Spot Apps)

## Summary

Implemented soft workload placement: managed node groups are the On-Demand **critical** floor; Karpenter nodes are labeled for **spot-tolerant** apps; system operators and stateful chart data pin to critical; stateless apps prefer Spot. Optional MNG taints are supported in the EKS module but left disabled.

## Context

The strategy in `docs/workload-placement.md` required concrete labels, capacity types, and scheduling so critical pods (system + stateful data) no longer compete equally with interruptible Spot workers. Development MNG was previously Spot, which undermined a stable critical floor.

## Before

* Dev MNG: `capacity_type = SPOT`, labels `role=general`.
* Prod MNG: On-Demand, labels `role=general` (no workload-class).
* Karpenter NodePools: no `workload-class` labels; controller unpinned.
* Argo CD / ESO / ALB install note: no critical nodeSelector.
* No optional taints field on node groups.

## After

* Dev and prod MNG labeled `workload-class=critical`, `role=critical` (plus existing az/env).
* Dev MNG switched to **ON_DEMAND** (critical floor; Spot only via Karpenter).
* Optional `taints` on MNG (module + env variables); commented example in tfvars for Phase 2.
* Karpenter controller `nodeSelector.workload-class=critical`.
* NodePool templates label nodes `workload-class=spot-tolerant`, `role=spot-tolerant`.
* Argo CD `global.nodeSelector`, ESO (+ webhook, certController) critical pin.
* ALB controller helm output includes `--set nodeSelector.workload-class=critical`.
* Docs: `workload-placement.md` status updated; `DEPLOYMENT.md` Phase 1b-extra.

## Technical Design Decisions

* **Soft placement first** — required selectors for critical only; preferred Spot affinity for apps; no taints yet (avoids breaking CoreDNS/DaemonSets).
* **On-Demand MNG in dev** — stability over max Spot discount for the floor; elastic Spot remains on Karpenter.
* **Taints as optional module feature** — ready for Phase 2 without enabling today.
* **System pins in Terraform Helm values** — operators must survive Spot consolidation.

## Implementation Details

1. Extended `modules/eks` node group schema with optional `taints`; wire dynamic `taint` blocks.
2. Env `variables.tf` / `main.tf` pass `taints` through for development and production.
3. Updated both `terraform.tfvars` node group labels and dev capacity type.
4. Karpenter Helm values + node-resources chart label templates.
5. Argo CD and ESO module Helm values; env ALB controller output strings.
6. Documented apply/verify steps.

## Files Changed

**Module / env:**

* `modules/eks/main.tf`, `modules/eks/variables.tf` — taints support.
* `modules/karpenter/main.tf` — controller nodeSelector.
* `modules/karpenter/charts/node-resources/templates/nodepool-*.yaml` — node labels.
* `modules/argocd/main.tf`, `modules/external-secrets/main.tf` — critical pins.
* `environments/development/*`, `environments/production/*` — labels, OD floor, taints passthrough, ALB output.

**Documentation:**

* `docs/workload-placement.md` — implementation status.
* `docs/DEPLOYMENT.md` — Phase 1b-extra.
* `docs/changes/2026-07-10-implement-workload-placement-phase1.md` — this record.

## Dependencies and Cross-Repository Impact

* **Requires chart change** for app-level schedulingRules (critical STS + Spot prefer).  
  Related: `techx-corp-chart/docs/changes/2026-07-10-implement-workload-placement-phase1.md`
* Apply **infra before** chart so `workload-class=critical` exists on nodes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | After chart sync: critical STS schedule only on labeled MNG; apps prefer Spot |
| **Infrastructure** | Dev MNG SPOT→ON_DEMAND may replace node groups; label updates in-place for prod |
| **Deployment** | Terraform apply first; then Helm/Argo chart |
| **Cost** | Dev fixed MNG cost rises toward On-Demand list price; Spot savings move to Karpenter apps |
| **Reliability** | Critical floor no longer Spot-interruptible in dev; system operators pinned to MNG |
| **Backward compatibility** | Pods without selectors still schedule anywhere (soft mode) |
| **Observability** | No change to metrics pipelines; verify pod→node placement with kubectl |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform validate | `terraform validate` (development) | ✅ Pass |
| Terraform fmt | `terraform fmt -recursive` | ✅ Applied |

### Manual Verification

* Reviewed NodePool YAML labels and controller nodeSelector in module templates.
* Live apply not run in this session (needs AWS credentials + cluster API).

### Remaining Verification (Post-Merge)

```bash
terraform -chdir=environments/development plan
terraform -chdir=environments/development apply
kubectl get nodes -L workload-class,karpenter.sh/capacity-type,role
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter -o wide
```

Re-install/upgrade ALB controller with updated output helm command if already installed without nodeSelector.

## Migration or Deployment Notes

1. **Plan carefully in development:** capacity_type change replaces Spot MNGs with On-Demand MNGs — expect node turnover.
2. Apply Terraform, confirm node labels, then sync chart.
3. Do **not** enable MNG taints until DaemonSets and critical pods have Phase 2 tolerations.
4. Existing ALB controller: re-run helm upgrade with critical nodeSelector from terraform output.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Dev node group replacement downtime | Medium | Medium | Apply in window; multi-AZ STS; raise desired temporarily |
| Critical pods Pending (labels missing) | Medium | High | Apply infra before chart; check node labels |
| Karpenter controller Pending (no critical nodes) | Low | High | Keep min MNG size ≥ 1 per AZ; labels on both NGs |

**Rollback procedure:**

1. Revert tfvars labels/capacity and module pins; re-apply.
2. Drain/replace nodes if needed.
3. Chart rollback separately (see chart change doc).
