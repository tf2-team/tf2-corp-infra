# Change: Enforce Managed Node Group vs Karpenter Hard Pod Placement

## Summary

Implemented hard placement between Critical managed node groups and Karpenter: pin Karpenter to **1.13.1**, add system MNG (`system-1a`/`system-1b`), apply `workload-class=spot-tolerant:NoSchedule` taints with NodePool weights and per-pool disruption budgets, and pin CoreDNS / EBS CSI controller (plus existing system operators) to the critical floor.

## Context

Soft placement (preferred Spot affinity + critical STS selectors) left classified stateless apps free to pack onto the MNG floor and did not isolate Karpenter capacity with taints. Kubernetes **1.36** requires Karpenter **≥ 1.13**. The rollout plan is development-first with capacity gates before production promotion.

* Plan: workspace `docs/plan/13422026.md`
* Prior soft placement: `docs/changes/2026-07-10-implement-workload-placement-phase1.md`

## Before

* Karpenter chart pin `1.3.3`; NodePools named `spot` / `on-demand-fallback` (or single `on-demand`) without taints.
* Critical floor = `general-1a` / `general-1b` only (labels critical; no separate system groups).
* No Terraform inputs for NodePool taints, weights, or per-pool disruption budgets.
* CoreDNS / EBS CSI add-ons without critical `nodeSelector` configuration.
* Chart-side scheduling was soft preference (see chart change record).

## After

* `karpenter_chart_version = "1.13.1"` (CRD + controller share the pin).
* NodePools: `stateless-spot` (weight 100) + `stateless-on-demand` (weight 10) when Spot preferred; production stays On-Demand-only until a separate Spot enablement.
* Both pools: labels + taint `workload-class=spot-tolerant:NoSchedule`.
* Migration disruption budgets `"0"` / `"0"` (per NodePool, not a global cluster budget).
* New MNG `system-1a` / `system-1b`: `t3.medium`, On-Demand, `min=1` `desired=1` `max=2`, labels critical, **no taint**.
* Legacy `general-*` retained for dual-run; capacity/lifecycle intentionally unchanged in this change to avoid accidental replace.
* CoreDNS and EBS CSI **controller** configuration_values pin `workload-class=critical`; EBS CSI **node** remains universal.
* Docs updated for hard placement, scaling semantics (no CA in Phase 1), and upgrade order.

## Technical Design Decisions

* **One-way isolation** — Karpenter taint + selectors; MNG remains untainted so unclassified pods can still schedule on MNG (admission/MNG taint is follow-up).
* **NodePool weight for Spot-first** — explicit weights instead of inferring order from shared labels.
* **Per-NodePool disruption budgets** — documented that steady-state `"1"`+`"1"` is not “one node cluster-wide”.
* **system MNG create + keep general** — migration dual-run; destroy legacy only after acceptance with a reviewed plan.
* **No Cluster Autoscaler** — `max_size` is ceiling only; scale-out is a separate Terraform review.
* **Do not rollback Karpenter to 1.3.3 on k8s 1.36**.

## Implementation Details

1. Extended `modules/karpenter` with `node_taints`, `nodepool_weights`, `disruption_budget_nodes`; default chart version `1.13.1`.
2. Replaced NodePool templates with `stateless-spot` / `stateless-on-demand` rendering taints, weights, budgets.
3. Wired new variables through development and production env modules + tfvars.
4. Added `system-1a` / `system-1b` node groups; left `general-*` as-is for dual-run.
5. Set CoreDNS and EBS CSI controller add-on configuration_values for critical nodeSelector.
6. Updated `docs/workload-placement.md`, `docs/karpenter.md`, and this change record.

## Files Changed

**Module / env:**

* `modules/karpenter/variables.tf` — new inputs, validations, default version 1.13.1.
* `modules/karpenter/main.tf` — pass taints/weights/budgets into node-resources Helm values; weight check.
* `modules/karpenter/charts/node-resources/templates/nodepool-spot.yaml` — new Spot NodePool.
* `modules/karpenter/charts/node-resources/templates/nodepool-on-demand.yaml` — new OD NodePool.
* `modules/karpenter/charts/node-resources/values.yaml` — chart defaults for weights/budgets/taints.
* Removed `nodepool-primary.yaml` / `nodepool-fallback.yaml`.
* `environments/development/*`, `environments/production/*` — variables, module wiring, tfvars (version, taints, budgets, system MNG, add-ons).

**Documentation:**

* `docs/workload-placement.md` — hard placement status and migration outline.
* `docs/karpenter.md` — 1.13.1 pin, new vars, upgrade order.
* `docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md` — this record.

## Dependencies and Cross-Repository Impact

* **Requires chart hard placement** so pods tolerate Karpenter taints and critical apps pin to MNG.  
  Related: `techx-corp-chart/docs/changes/2026-07-11-enforce-managed-karpenter-pod-placement.md`
* Apply order: inventory → Karpenter upgrade → create system MNG → capacity gate → pin controllers / NodePool taints → chart sync → AZ migrate → open budgets → remove legacy.
* No `techx-corp-platform` changes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | After chart sync: classified stateless pods only on Karpenter; critical only on critical-labeled MNG |
| **Infrastructure** | +2 On-Demand system MNG nodes during dual-run; Karpenter multi-minor upgrade |
| **Deployment** | Saved Terraform plans required; CRD before controller; dual-run until acceptance |
| **Performance** | Possible Pending if capacity gate fails on `t3.medium` system nodes |
| **Security** | Narrower scheduling surface for classified workloads; no new broad IAM `*` expansions in this change |
| **Reliability** | Hard isolation reduces critical/stateless packing contention; migration risk on PVC/AZ |
| **Cost** | Temporary dual MNG cost; Spot savings remain on Karpenter app tier |
| **Backward compatibility** | NodePool rename replaces old `spot`/`on-demand-fallback` CRs via Helm; pods need chart tolerations before taint is useful |
| **Observability** | Prometheus/Grafana/Jaeger critical pin is on chart side |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt | `terraform fmt -recursive` | ✅ Applied |
| Terraform validate (dev) | `terraform -chdir=environments/development validate` | ✅ Pass |
| Terraform validate (prod) | `terraform -chdir=environments/production validate` | ✅ Pass |

### Manual Verification

* Source review of NodePool templates (names, weights, taints, budgets).
* Live apply **not** executed in this session (requires AWS credentials, cluster API, and reviewed plan artifact).

### Remaining Verification (Post-Merge)

1. Phase 0 live inventory + source/live drift check.
2. Saved plan: create `system-*` only; **no** replace/destroy of `general-*`.
3. Karpenter CRD then controller Ready; NodePool/EC2NodeClass Ready.
4. Capacity preflight on real allocatable; PVC/AZ inventory before cordon.
5. Runtime gates, canaries A/B/C, smoke test; Terraform idempotent before prod promotion.

## Migration or Deployment Notes

1. Do not apply production until development Definition of Done.
2. Upgrade path: freeze unrelated changes → Karpenter 1.13.1 → system MNG → pins → NodePool taint → chart → migrate AZ-by-AZ.
3. If capacity fails: uncordon legacy, stop, open separate capacity remediation PR.
4. Production initial: On-Demand NodePool only (`karpenter_spot_preferred = false`); Spot is a later rollout.
5. Never downgrade Karpenter to 1.3.3 on Kubernetes 1.36.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Multi-minor Karpenter upgrade issues | Medium | High | CRD first; budget `"0"`; hold placement if controller unhealthy |
| `t3.medium` system under-capacity | Medium | High | Preflight + dual-run; do not delete legacy early |
| PVC/AZ mismatch | Medium | High | Inventory PV topology; migrate one AZ at a time |
| Universal DS missing taint toleration | Medium | High | Gate before applying NodePool taints |
| NodePool rename churn | Medium | Medium | Apply during maintenance; drain old pool nodes carefully |

**Rollback procedure:**

1. Uncordon legacy MNG if needed.
2. Roll back chart hard placement and/or remove NodePool taints while keeping Karpenter **1.13.1**.
3. Do not destroy system MNG without a reviewed plan.
4. Karpenter version downgrade is a separate incident plan only if forced by an emergency and re-checked against k8s compatibility.
