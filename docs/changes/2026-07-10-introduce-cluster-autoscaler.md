# Change: Introduce Optional Cluster Autoscaler (Off by Default)

## Summary

Added an optional Cluster Autoscaler (CA) Terraform module and environment wiring so operators can scale EKS managed node group ASGs when deliberately choosing CA-only mode. **All CA flags default to false** in development and production. The platform default remains **small managed node groups (fixed floor) + Karpenter (elastic capacity)**. Dual Helm install of CA and Karpenter is blocked by a Terraform `check`.

## Context

The platform already uses Karpenter for flexible node autoscaling next to a small system MNG. Some scenarios still benefit from classic Cluster Autoscaler behavior (grow predefined MNGs within `min`/`max`). CA was previously documented as “do not install” without a ready-to-enable code path. This change introduces CA as a **flagged, off-by-default** alternative without changing the default runtime path.

## Before

* Worker elastic capacity: **Karpenter only** (plus static MNGs).
* No `modules/cluster-autoscaler`, no CA IRSA/Helm, no MNG ASG discovery tags for CA.
* Docs stated not to install CA alongside Karpenter, with no optional module.

## After

* New `modules/cluster-autoscaler`: IRSA + least-privilege IAM, optional Helm chart install.
* EKS module can tag MNG ASGs for CA auto-discovery when `enable_cluster_autoscaler_asg_tags` is true (wired from `cluster_autoscaler_enabled`).
* Dev/prod tfvars: `cluster_autoscaler_enabled = false`, `cluster_autoscaler_install_helm = false`.
* Terraform `check "no_dual_node_autoscalers"` fails if CA Helm is on while Karpenter Helm or NodePools are on.
* Docs: `docs/cluster-autoscaler.md`; updates to `docs/karpenter.md` and `docs/DEPLOYMENT.md`.

## Technical Design Decisions

* **Mirror ESO/Karpenter pattern:** `enabled` for AWS/IAM; `install_helm` for cluster install (needs API at apply).
* **Default off:** no cost or behavior change until flags are flipped.
* **Hard mutual exclusion** on active install flags rather than soft docs only (dual controllers thrash).
* **ASG tags only when CA enabled:** avoids unnecessary ASG tag churn while CA is unused; tags applied when IAM path is prepared.
* **IAM mutate actions tag-conditioned** on `k8s.io/cluster-autoscaler/<cluster>=owned`.
* **Chart pin `9.46.6`:** reproducible Helm from `kubernetes.github.io/autoscaler`; bump via tfvars when needed.
* **Rejected:** enabling CA by default; running CA + Karpenter together “safely”; Argo CD-managed CA in v1.

## Implementation Details

1. Created `modules/cluster-autoscaler` with IRSA trust on `kube-system/cluster-autoscaler`, IAM policy (describe + tag-scoped SetDesiredCapacity/Terminate), optional `helm_release` with AWS auto-discovery values.
2. Extended `modules/eks` with `enable_cluster_autoscaler_asg_tags` and `aws_autoscaling_group_tag` resources for enabled/owned tags per MNG ASG.
3. Wired `module "cluster_autoscaler"` and the dual-autoscaler `check` in development and production `main.tf`.
4. Added env variables, outputs (`role_arn`, `helm_installed`, `bootstrap_note`), and explicit **false** tfvars for both environments.
5. Documented enable/disable runbook and verification.

## Files Changed

**Module (new):**

* `modules/cluster-autoscaler/main.tf` — IRSA, IAM, optional Helm.
* `modules/cluster-autoscaler/variables.tf` — flags and chart knobs.
* `modules/cluster-autoscaler/outputs.tf` — role ARN, helm_command, bootstrap_note.
* `modules/cluster-autoscaler/versions.tf` — aws + helm providers.

**EKS:**

* `modules/eks/main.tf` — ASG discovery tags for CA.
* `modules/eks/variables.tf` — `enable_cluster_autoscaler_asg_tags`.

**Environments:**

* `environments/development/main.tf` — CA module + dual-autoscaler check; EKS ASG tag flag.
* `environments/development/variables.tf` — CA variables (default false).
* `environments/development/outputs.tf` — CA outputs.
* `environments/development/terraform.tfvars` — CA flags false; comments.
* `environments/production/main.tf` — same as development.
* `environments/production/variables.tf` — CA variables (default false).
* `environments/production/outputs.tf` — CA outputs.
* `environments/production/terraform.tfvars` — CA flags false; comments.

**Documentation:**

* `docs/cluster-autoscaler.md` — operator guide.
* `docs/karpenter.md` — optional CA reference; dual-run still unsupported.
* `docs/DEPLOYMENT.md` — Phase 1c.
* `docs/changes/2026-07-10-introduce-cluster-autoscaler.md` — this change record.

## Dependencies and Cross-Repository Impact

None. Self-contained in `techx-corp-infra`. No chart or platform changes required. Default Karpenter path unchanged.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change with default flags |
| **Infrastructure** | Optional CA IRSA/ASG tags when enabled; zero resources when disabled |
| **Deployment** | No new required steps; CA opt-in only |
| **Performance** | N/A at default |
| **Security** | IRSA + tag-conditioned mutate actions when enabled |
| **Reliability** | Dual-controller risk mitigated by Terraform check and defaults |
| **Cost** | Zero at default; CA-only mode bills extra MNG nodes within max_size |
| **Backward compatibility** | Fully additive |
| **Observability** | CA pod logs when installed |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform validate (dev) | `terraform -chdir=environments/development init -backend=false && validate` | Pass |
| Terraform validate (prod) | `terraform -chdir=environments/production init -backend=false && validate` | Pass |
| Defaults keep CA off | tfvars `cluster_autoscaler_* = false` | Confirmed in both envs |

### Manual Verification

* Code review of module gating (`enabled` / `install_helm` counts).
* Confirmed mutual-exclusion `check` condition covers Karpenter Helm and NodePool create flags.

### Remaining Verification (Post-Merge)

* `terraform plan` on development and production with default tfvars: no CA IAM/Helm creates.
* Optional non-prod CA-only drill per `docs/cluster-autoscaler.md` (operator-owned).

## Migration or Deployment Notes

None for default path. Operators enabling CA must:

1. Disable Karpenter install/NodePools and drain Karpenter nodes.
2. Ensure MNG `max_size` headroom.
3. Set `cluster_autoscaler_enabled = true`, apply.
4. Set `cluster_autoscaler_install_helm = true`, apply.
5. Verify deployment and scale-test.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Accidental dual enable | Low | High | Terraform check; defaults false; docs |
| CA cannot scale Karpenter nodes | Medium (misunderstanding) | Low | Docs clarify MNG-only |
| Helm apply without API | Medium | Low | Keep install_helm false until kube ready |

**Rollback procedure:**

1. Set `cluster_autoscaler_install_helm = false` and apply.
2. Set `cluster_autoscaler_enabled = false` and apply.
3. Re-enable Karpenter flags for the default capacity model.
