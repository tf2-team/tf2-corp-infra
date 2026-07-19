# Change: Hybrid Cluster Autoscaler on System MNG (with Karpenter)

## Summary

Enabled **Cluster Autoscaler (CA)** to scale only the **system-\*** managed node group ASGs while **Karpenter** continues to provision elastic spot-tolerant application capacity. Removed the previous mutual-exclusion Terraform check that blocked running CA Helm and Karpenter together, scoped ASG discovery tags to `system-*` groups, and ignored Terraform `desired_size` drift so CA scale actions are not reverted on apply.

## Context

Critical workloads (`workload-class=critical`) run on On-Demand system managed node groups. Stateless apps run on Karpenter. Previously CA was off by default and documented as CA-only (disable Karpenter first), so the critical floor could not grow automatically when system pods went Pending—only a manual Terraform `desired_size`/`max_size` change could help.

Operators need automatic system-floor headroom without giving CA ownership of Karpenter-provisioned nodes. That hybrid split is valid because Karpenter nodes are not Auto Scaling Group members.

## Before

* `cluster_autoscaler_enabled` / `cluster_autoscaler_install_helm` were **false** in development and production.
* Terraform `check "no_dual_node_autoscalers"` failed if both CA Helm and Karpenter install/NodePools were enabled.
* EKS tagged **all** MNG ASGs when CA tags were on (no system-only filter).
* Node group `desired_size` was fully managed by Terraform (CA scale would thrash on next apply).
* System MNG `max_size` was **2** (little or no CA headroom when desired already equaled max).
* Docs described CA as optional CA-only and dual-run with Karpenter as unsupported.

## After

* Hybrid model is the default capacity path:
  * **CA** → tagged `system-*` MNG ASGs within `min_size`/`max_size`
  * **Karpenter** → spot-tolerant / elastic app nodes
* Both envs: `cluster_autoscaler_enabled = true`, `cluster_autoscaler_install_helm = true`.
* Dual-autoscaler check **removed**.
* EKS tags only node group keys matching `cluster_autoscaler_node_group_name_prefixes` (default `system-`).
* `aws_eks_node_group` ignores `scaling_config[0].desired_size` after create.
* Headroom: development `max_size=3`; production system-1a `max_size=4`, system-1b `max_size=3`.
* CA Helm Deployment uses `nodeSelector: workload-class=critical`.
* Docs updated (`cluster-autoscaler.md`, `workload-placement.md`, `karpenter.md`, `DEPLOYMENT.md`).

## Technical Design Decisions

* **Coexistence over mutual exclusion:** CA and Karpenter do not compete for the same capacity plane when ASG tags are scoped to system MNGs only.
* **Prefix filter (`system-`)** instead of tagging every MNG so any future non-system MNG is not accidentally CA-managed.
* **Always ignore `desired_size`:** Terraform cannot conditionally set `lifecycle.ignore_changes`; permanent ignore is the correct pattern once CA owns desired capacity. Bootstrap floor remains in tfvars for first create; operators raise floors via `min_size`.
* **Modest max_size increases:** enough for Pending critical pods without an open-ended cost ceiling.
* **Rejected:** CA-only mode (would remove Spot elasticity); CA on all MNGs without filter; leaving desired_size managed by Terraform.

## Implementation Details

1. Extended `modules/eks` with `cluster_autoscaler_node_group_name_prefixes` and `local.cluster_autoscaler_node_groups` so ASG tags apply only to matching keys.
2. Added `lifecycle.ignore_changes = [scaling_config[0].desired_size]` on managed node groups.
3. Updated `modules/cluster-autoscaler` Helm values: critical `nodeSelector`, `skip-nodes-with-local-storage`, hybrid comments/bootstrap note.
4. Removed `check "no_dual_node_autoscalers"` from development and production `main.tf`.
5. Enabled CA flags and raised system MNG `max_size` in both `terraform.tfvars`.
6. Rewrote operator docs for hybrid mode.

## Files Changed

**Modules:**
* `modules/eks/main.tf` — system-only CA ASG tags; ignore desired_size.
* `modules/eks/variables.tf` — `cluster_autoscaler_node_group_name_prefixes`.
* `modules/cluster-autoscaler/main.tf` — hybrid Helm values / comments.
* `modules/cluster-autoscaler/variables.tf` — description updates.
* `modules/cluster-autoscaler/outputs.tf` — hybrid bootstrap note.

**Environments:**
* `environments/development/main.tf` — remove dual check.
* `environments/production/main.tf` — remove dual check.
* `environments/development/variables.tf` — CA variable descriptions.
* `environments/production/variables.tf` — CA variable descriptions.
* `environments/development/terraform.tfvars` — enable CA; max_size=3.
* `environments/production/terraform.tfvars` — enable CA; max_size=4/3.

**Documentation:**
* `docs/cluster-autoscaler.md` — hybrid operator guide.
* `docs/workload-placement.md` — CA on critical floor.
* `docs/karpenter.md` — coexistence notes.
* `docs/DEPLOYMENT.md` — Phase 1c hybrid.
* `docs/changes/2026-07-19-hybrid-cluster-autoscaler-system-mng.md` — this change record.

## Dependencies and Cross-Repository Impact

None. Chart scheduling rules already pin critical pods to `workload-class=critical` and stateless apps to Karpenter; no chart change is required for CA to act on the system floor.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Critical Pending pods can trigger system MNG scale-out within max_size; app Spot capacity still via Karpenter |
| **Infrastructure** | CA IRSA + Helm Deployment; ASG tags on system-* only; higher max_size ceilings |
| **Deployment** | Requires Terraform apply with cluster API (Helm install); no Argo chart change |
| **Performance** | Faster relief for critical-node pressure vs manual Terraform desired changes |
| **Security** | Unchanged IAM shape (tag-conditioned ASG mutate); controller pinned to critical nodes |
| **Reliability** | Hybrid autoscaling; scale-down remains conservative on system pods |
| **Cost** | Possible additional On-Demand system nodes up to max_size when critical demand grows |
| **Backward compatibility** | Operators who relied on dual-exclusion must follow new hybrid docs; CA-only path no longer required |
| **Observability** | Standard CA metrics/logs in `kube-system` |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Static review | File/module wiring review | ✅ Completed |
| Terraform apply | Not run in this change (needs operator approval + cluster API) | ⏳ Pending |

### Manual Verification

None in-session (no `terraform apply`).

### Remaining Verification (Post-Merge)

1. `terraform plan` / `apply` development, then production (cluster API reachable).
2. Confirm CA Deployment Ready and ASG tags on system groups only.
3. Critical-only scale test per `docs/cluster-autoscaler.md` §6.
4. Confirm Karpenter still provisions for spot-tolerant Pending pods.

## Migration or Deployment Notes

1. Prerequisites: kubeconfig for the target cluster; same IAM as other Helm-based modules (Karpenter/Argo CD).
2. Apply development first:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/development plan -out=tfplan
terraform -chdir=environments/development apply tfplan
```

3. Verify CA pods and ASG tags, then apply production with the same pattern.
4. Optional: watch cost/ASG desired after soak; raise or lower `max_size` via a follow-up Terraform change if needed.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Extra On-Demand system cost up to max_size | Medium | Medium | Cap max_size; monitor ASG desired |
| CA scale-down of lightly loaded critical nodes | Low | Medium | skip-nodes-with-system-pods; conservative timers |
| Helm install fails without API access | Medium | Low | install_helm=false until API ready; re-apply |
| Accidental CA on non-system MNG | Low | High | Prefix filter default `system-` only |

**Rollback procedure:**

1. Set `cluster_autoscaler_install_helm = false` and apply.
2. Set `cluster_autoscaler_enabled = false` and apply (removes IRSA + ASG tags).
3. Optionally restore previous `max_size` values and re-apply.
4. Karpenter remains available for app capacity throughout.

<!-- Change trail: @hungxqt - 2026-07-19 - Hybrid Cluster Autoscaler on system MNG with Karpenter coexistence. -->
