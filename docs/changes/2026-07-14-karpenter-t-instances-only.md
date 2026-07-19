# Change: Karpenter T-Family Instances Only

## Summary

Changed the Karpenter module default `instance_categories` allow-list from compute/memory/general purpose families `["c", "m", "r"]` to burstable **`["t"]`**, so NodePools only provision T-family EC2 instances (with the current `arch=arm64` requirement, primarily `t4g.*`).

## Context

* Cost and capacity posture for this workspace prefers burstable T instances (same class already used for managed node groups such as `t3` / `t4g`).
* Karpenter was free to pick larger non-burstable families (`c`/`m`/`r`), which can raise cost and diverge from the MNG floor.
* Why now: align elastic Karpenter capacity with the T-instance preference without requiring per-environment overrides.

## Before

* `modules/karpenter` NodePool requirements used:

  ```hcl
  key      = "karpenter.k8s.aws/instance-category"
  operator = "In"
  values   = ["c", "m", "r"]  # variable default
  ```

* With `kubernetes.io/arch In ["arm64"]`, Karpenter selected Graviton **c/m/r** families, not `t4g`.
* Docs (`docs/karpenter.md`, `docs/cpu-architecture.md`) documented the c/m/r default and that `t4g` was not in the allow-list.

## After

* Module default:

  ```hcl
  variable "instance_categories" {
    default = ["t"]
  }
  ```

* Both Spot and On-Demand NodePool requirement bases inherit `instance-category In ["t"]`.
* With existing constraints (`arch=arm64`, `instance-generation Gt 2`, `min_instance_cpu = 2`), Karpenter provisions **T-family** instances only — primarily **`t4g.*`** on arm64.
* Operators can still override via `instance_categories` if the module input is wired from an environment later; the new default is T-only without env changes (envs already rely on the module default and do not pass this input today).

## Technical Design Decisions

* **Change module default rather than hard-code in templates** — keeps the single allow-list variable as the control plane; templates already range over requirements built in `main.tf`.
* **Do not add env-level variables in this change** — development and production already omit `instance_categories`; updating the default is sufficient and avoids duplicate wiring.
* **Keep arch / generation / min-CPU filters** — T-only does not remove pod-density guards (`min_instance_cpu = 2`) or arm64 posture.
* **Rejected:** listing explicit instance types (`t4g.medium`, …) — category `t` is broader Spot diversity and matches Karpenter best practice for flexibility within the family.

Known limitation: existing running NodeClaims on c/m/r are not terminated solely by this CR update; consolidation/expiry/replacement will move capacity to T over time, or operators can drain non-T Karpenter nodes after apply.

## Implementation Details

1. Set `instance_categories` default to `["t"]` in `modules/karpenter/variables.tf`.
2. Updated operator docs that described the old c/m/r default and troubleshooting table for wrong families.
3. No NodePool template YAML changes — requirements are still injected via Helm values from Terraform locals.

## Files Changed

**Module:**
* `modules/karpenter/variables.tf` — Default `instance_categories` to `["t"]`.

**Documentation:**
* `docs/karpenter.md` — Module inputs note for T-family default.
* `docs/cpu-architecture.md` — Wiring table and troubleshooting row for T-family selection.
* `docs/changes/2026-07-14-karpenter-t-instances-only.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart and platform image contracts are unchanged. Managed node group instance types are not modified by this change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No pod API change; new elastic nodes are T-family only |
| **Infrastructure** | Karpenter NodePool instance-category allow-list narrowed to `t` |
| **Deployment** | Requires Terraform apply that refreshes the `karpenter-node-resources` Helm release (when `create_node_resources` is true) |
| **Performance** | Burstable CPU credits may throttle under sustained high CPU vs c/m/r; typical for T floors |
| **Security** | No change |
| **Reliability** | Spot diversity limited to T offerings in-region; still multi-size within `t` |
| **Cost** | Expected lower list/Spot spend vs unrestricted c/m/r for similar vCPU; credit-based billing for T |
| **Backward compatibility** | New provisioned nodes only; existing non-T Karpenter nodes remain until disrupted/replaced |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Default string | Inspect `modules/karpenter/variables.tf` | ✅ `default = ["t"]` |
| Requirement wiring | Inspect `modules/karpenter/main.tf` locals | ✅ Uses `var.instance_categories` (no hard-code) |

### Manual Verification

* Confirm no environment currently overrides `instance_categories` (none wired in `environments/*/main.tf`).

### Remaining Verification (Post-Merge)

1. Apply development Terraform (cluster API + Helm node-resources release).
2. Inspect NodePools:

   ```cmd
   kubectl get nodepool -o yaml
   ```

   Expect `karpenter.k8s.aws/instance-category` values include only `t`.
3. Optional scale-test / Pending load; verify new nodes are `t4g.*` (arm64):

   ```cmd
   kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool,kubernetes.io/arch
   ```

## Migration or Deployment Notes

1. Apply the environment that manages Karpenter NodePools (typically development first).
2. Optional: drain existing Karpenter nodes that are not T-family so replacements land on T sooner.
3. Production only affected when `karpenter_create_node_resources` is true and NodePools are installed from this module revision.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Insufficient Spot T capacity in AZ | Low | Medium | Multi-AZ already required; temporarily widen `instance_categories` or rely on On-Demand T pool |
| Sustained CPU credit exhaustion on T | Medium | Medium | Raise min size / NodePool limits; or temporarily re-allow c/m/r |
| Existing non-T nodes linger | Medium | Low | Drain/consolidate after apply |

**Rollback procedure:**

1. Set `instance_categories` default (or override) back to `["c", "m", "r"]`.
2. Re-apply Terraform so NodePools update.
3. Optionally drain T-only nodes if c/m/r capacity is required immediately.

<!-- Change trail: @hungxqt - 2026-07-14 - Karpenter NodePools restricted to t-family instances. -->
