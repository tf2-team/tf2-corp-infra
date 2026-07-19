# Change: Align Production Terraform with Development Behavior

## Summary

Production Terraform (`environments/production`) was updated so its **operational model matches development**: critical ARM managed-node floor only, Karpenter Spot-preferred with Helm/NodePools and consolidation budgets, Argo CD enabled, open storefront ALB paths, short ECR retention, and force-delete ASM recovery. Production **identity** (names, CIDR, GitHub production role/env/refs, state key) is unchanged.

## Context

* Development already runs the target capacity and GitOps model (system-* MNG + Karpenter Spot + Argo CD).
* Production still used a conservative dual-run layout (legacy `general-*` x86 MNGs, Karpenter/Argo CD install deferred, On-Demand-only NodePools, disruption freeze).
* Operators need production to behave like development for consistent placement, cost shape, and feature parity before/during further cutovers.

## Before

* **Node groups:** `general-1a/1b` (`t3.large` x86) + `system-1a/1b` (`t3.medium` x86).
* **ECR:** keep last **20** images.
* **Add-ons:** unpinned addon versions (except configuration JSON).
* **Argo CD:** `argocd_enabled = false`.
* **Storefront ALB:** `storefront_alb_block_sensitive_paths = true`.
* **Secrets Manager:** recovery window default **30** days (not overridden in tfvars).
* **Karpenter:** IAM on; Helm/NodePools **off**; `spot_preferred = false`; disruption budgets `"0"`/`"0"`; no `consolidate_after` wiring; CPU/memory limits 64 / 128Gi.
* **variables.tf:** missing `karpenter_consolidate_after`; prod-lean defaults for spot, budgets, ECR count, recovery window.

## After

* **Node groups:** only `system-1a/1b` on **`t4g.medium` / AL2023 ARM** (same topology as development); labels use `env = production`.
* **ECR:** keep last **5** images (+ 1 buildcache).
* **Add-ons:** pinned versions for vpc-cni, coredns, kube-proxy (same pins as development).
* **Argo CD:** `argocd_enabled = true` with chart repo URL for main.
* **Storefront ALB:** path blocking **false** (all paths allowed, same as development).
* **Secrets Manager:** `secrets_manager_recovery_window_in_days = 0`.
* **Karpenter:** `install_helm` + `create_node_resources` **true**; Spot preferred; budgets `"1"`/`"1"`; `consolidate_after = "1m"`; limits 32 CPU / 64Gi; `consolidate_after` passed in `main.tf`.
* **Preserved production identity:** `project_name`, `cluster_name`, `ecr_project_name`, VPC `10.0.0.0/16`, GHA prod role/env/`main`+tags refs, S3 state key `production/terraform.tfstate`, ASM prefix default `techx-corp/production`.

## Technical Design Decisions

* **Behavioral parity, not identity merge:** production must not share development CIDR, state key, or GitHub environment subjects.
* **ARM MNG + Spot Karpenter:** matches development cost/placement contract; requires ARM-compatible workload images (already expected in dev).
* **Removing `general-*`:** ends dual-run capacity in prod config; existing clusters with `general-*` will plan to destroy those node groups — operators must drain/accept before apply.
* **Enable Argo CD / Karpenter Helm by default in tfvars:** same as development; apply requires reachable cluster API (kubeconfig).
* **Rejected:** renaming production to development identity (would collide with existing AWS resources and GitHub environments).

## Implementation Details

1. Rewrote `environments/production/terraform.tfvars` to mirror development operational settings.
2. Updated `environments/production/variables.tf` defaults (ECR keep 5, ASM recovery 0, Spot preferred, disruption 1/1, CPU/memory 32/64Gi) and added `karpenter_consolidate_after`.
3. Wired `consolidate_after = var.karpenter_consolidate_after` on the production Karpenter module in `main.tf`.
4. Updated comments so production no longer documents “dev first / freeze until acceptance” as the steady state.

## Files Changed

**Configuration:**
* `environments/production/terraform.tfvars` — Full behavioral alignment with development; production identity retained.
* `environments/production/variables.tf` — Defaults and `karpenter_consolidate_after` variable.
* `environments/production/main.tf` — Pass `consolidate_after`; comment updates.

**Documentation:**
* `docs/changes/2026-07-12-align-production-with-development.md` — This change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-chart:** Production Argo CD bootstrap still uses `gitops/clusters/prod/`; chart workloads should tolerate ARM MNG + Karpenter Spot taints (`workload-class=spot-tolerant`) as in development.
* **techx-corp-platform:** Images pushed to `techx-prod-corp/*` should be multi-arch or ARM-compatible if pods schedule on `t4g` / Graviton Karpenter nodes.
* Related operational docs in this repo (`docs/workload-placement.md`, `docs/karpenter.md`) still describe an older “prod On-Demand first” path; treat this change as the new intended prod config (docs can be refreshed separately).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Same placement contract as development: critical on MNG, stateless on Karpenter Spot (with OD fallback). |
| **Infrastructure** | Drops `general-*` MNGs; switches system MNGs to ARM; enables Karpenter Helm/NodePools and Argo CD. |
| **Deployment** | `terraform apply` in production needs cluster API; may destroy legacy x86 node groups. |
| **Performance** | Smaller critical floor (`t4g.medium`); elastic capacity via Karpenter. |
| **Security** | Storefront sensitive paths no longer blocked at ALB (matches development). |
| **Reliability** | Spot interruptions possible for spot-tolerant workloads; consolidation budgets open (`1`/`1`). |
| **Cost** | Expected lower fixed MNG cost; Spot preferred for elastic nodes; ECR retention reduced to 5. |
| **Backward compatibility** | Breaking for clusters still depending on `general-*` x86 capacity without migration. |
| **Observability** | No change to metrics stack; Argo CD enabled for GitOps visibility. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Syntax review | Manual diff of prod vs dev tfvars/main/variables | ✅ Behavioral keys aligned |
| Terraform validate | `terraform -chdir=environments/production init -backend=false` then `validate` | ✅ Success |

### Manual Verification

* Compared `environments/development/terraform.tfvars` feature flags and topology to production after edit.
* Confirmed production retains distinct names, CIDR, GHA role/env, and state key.

### Remaining Verification (Post-Merge)

1. `terraform -chdir=environments/production init` (with backend config).
2. `terraform -chdir=environments/production plan` and review node-group destroy/create and Karpenter/Argo CD creates.
3. Ensure kubeconfig targets production cluster before apply if Helm resources will be installed.
4. Drain workloads off any existing `general-*` nodes before accepting destroy plans.
5. Confirm ARM image architecture for prod ECR tags.

## Migration or Deployment Notes

1. **Pre-apply:** `aws eks update-kubeconfig --name techx-tf2-prod --region us-east-1`.
2. Review plan for:
   * Destroy of `general-1a` / `general-1b` (if present in state).
   * Replace of system node groups (x86 → ARM).
   * Create of Karpenter Helm release + NodePools/EC2NodeClass.
   * Create of Argo CD Helm release.
3. Apply production after plan acceptance.
4. Bootstrap Argo apps from `techx-corp-chart/gitops/clusters/prod/` if not already present.
5. Do **not** enable Cluster Autoscaler Helm while Karpenter install/NodePools are active.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Node group replace drains pods / short capacity gap | Medium | High | Apply in maintenance window; ensure Karpenter can provision; review plan carefully |
| Spot capacity shortage | Medium | Medium | On-Demand NodePool remains at weight 10; can set `karpenter_spot_preferred = false` |
| Argo CD apply fails without API access | Medium | Medium | Set `argocd_enabled = false` temporarily; fix kube path; re-enable |
| x86-only images fail on ARM nodes | Medium | High | Publish multi-arch/ARM images before apply |
| ALB path openness exposes internal UIs | Low | Medium | Re-set `storefront_alb_block_sensitive_paths = true` if needed |

**Rollback procedure:**

1. Revert `environments/production/terraform.tfvars`, `variables.tf`, and `main.tf` to the prior commit.
2. `terraform plan/apply` to restore previous node groups, disable Karpenter Helm/NodePools and Argo CD if required, and re-enable ALB path blocks.
3. Re-apply chart values if storefront path posture was changed via Helm/GitOps.
