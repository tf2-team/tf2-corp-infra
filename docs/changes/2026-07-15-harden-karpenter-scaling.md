# Change: Harden Karpenter Scaling Policy

## Summary

Harden the development and production Karpenter configuration by replacing the floating AL2023 alias with an exact live-resolved release, expanding eligible ARM64 instance categories to `c`, `m`, and `r`, bounding NodeClaim lifetime and termination, retaining Spot-first On-Demand fallback, and limiting voluntary disruption to one node per NodePool. The change improves scale-out flexibility and scale-in predictability without applying infrastructure or mutating the live cluster.

## Context

The prior configuration used `al2023@latest`, restricted capacity to the `t` category, inherited the module's one-minute consolidation delay in both environments, and did not set `terminationGracePeriod`. A floating AMI could introduce unreviewed node-image changes, the narrow category set could increase Pending time during Spot scarcity, and an implicit termination deadline made disruption behavior harder to review. Read-only inspection showed that the live EC2NodeClass had resolved `al2023@latest` to release `v20260709`; that exact release is now the declared contract.

Constraints shaping the implementation:

* Terraform and Git remain the source of desired state; no direct Kubernetes, Helm, AWS, or Terraform mutation was performed.
* Production voluntary disruption stays bounded to `"0"` or `"1"` per NodePool.
* Critical managed-node capacity remains fixed and requires measured headroom before any reviewed size change.
* A development bake and reviewed saved plan are required before production promotion.

## Before

* The module and local node-resource chart defaulted to `al2023@latest`.
* Eligible instance categories defaulted to `t`.
* Development and production inherited the module's `1m` consolidation delay.
* NodeClaims expired after `720h`, but no explicit termination grace period was rendered.
* Environment wiring did not expose lifecycle and AMI policy as validated variables.
* Documentation described production as initially On-Demand-only and disruption budgets as frozen at zero.

## After

* Both environments declare the exact `al2023@v20260709` AMI alias; module validation rejects floating aliases.
* Both NodePools may select duplicate-free categories from the bounded `c`, `m`, and `r` set.
* NodeClaims render `expireAfter: 720h` and `terminationGracePeriod: 1h`.
* Consolidation waits `5m` in development and `10m` in production.
* Both environments retain Spot weight 100 and On-Demand fallback weight 10, with steady-state disruption budget `"1"` per pool.
* Production validation rejects a disruption budget other than `"0"` or `"1"`.
* Operator documentation defines capacity headroom, freeze, bake, promotion, and rollback gates.

## Technical Design Decisions

The AMI is pinned by exact Karpenter alias rather than AMI ID so the EC2NodeClass retains Karpenter's supported alias contract while avoiding unreviewed `@latest` drift. The release was taken from read-only live state, but it still requires a development NodeClaim bake before production use.

Replacing the `t`-only default with `c`, `m`, and `r` improves Spot capacity diversity while avoiding burstable-family credit behavior and without opening every EC2 category. Validation prevents empty, duplicate, or unsupported categories. The `720h` expiry bounds long-lived drift, while `1h` gives PDB-respecting drains a clear deadline; forced interruptions can still bypass voluntary-disruption budgets.

Budgets remain per NodePool, so both pools could each disrupt one node concurrently. Controlled template or AMI migrations therefore freeze both budgets at zero and reopen them one pool at a time after evidence. No Cluster Autoscaler or automatic critical-MNG scaling is introduced.

## Implementation Details

1. Added validated module inputs for exact AMI aliases, bounded instance categories, positive expiry durations, and positive termination grace periods.
2. Passed the termination grace period through Terraform into the local Helm chart.
3. Rendered `terminationGracePeriod` in the Spot and On-Demand NodePool templates.
4. Added validated environment variables and explicit development/production values for the AMI, categories, lifecycle, consolidation delay, and disruption budgets.
5. Added production input validation that rejects disruption budgets other than `"0"` or `"1"`.
6. Updated Karpenter and workload-placement documentation with steady-state policy, critical-capacity gates, staged disruption controls, and CMD-first verification.

## Files Changed

**Karpenter module:**

* `modules/karpenter/variables.tf` — Adds bounded categories, exact AMI validation, and termination-grace input.
* `modules/karpenter/main.tf` — Passes lifecycle settings to the node-resource chart.
* `modules/karpenter/charts/node-resources/values.yaml` — Sets secure, reviewable lifecycle defaults.
* `modules/karpenter/charts/node-resources/templates/nodepool-spot.yaml` — Renders Spot NodeClaim termination grace.
* `modules/karpenter/charts/node-resources/templates/nodepool-on-demand.yaml` — Renders On-Demand NodeClaim termination grace.

**Development environment:**

* `environments/development/variables.tf` — Exposes and validates environment Karpenter policy inputs.
* `environments/development/main.tf` — Wires the inputs into the module.
* `environments/development/terraform.tfvars` — Declares the pinned AMI, `c`/`m`/`r`, `720h`, `1h`, `5m`, and one-node budgets.

**Production environment:**

* `environments/production/variables.tf` — Exposes and validates environment Karpenter policy inputs, including the blocking zero-or-one disruption-budget guard.
* `environments/production/main.tf` — Wires the validated inputs into the module.
* `environments/production/terraform.tfvars` — Declares the pinned AMI, `c`/`m`/`r`, `720h`, `1h`, `10m`, and one-node budgets.

**Documentation:**

* `docs/karpenter.md` — Documents the exact policy, live alias evidence, headroom gates, and staged disruption sequence.
* `docs/workload-placement.md` — Aligns workload placement and rollout guidance across both environments.
* `docs/changes/2026-07-15-harden-karpenter-scaling.md` — This change record.

## Dependencies and Cross-Repository Impact

The production scheduling contract is implemented separately in `techx-corp-chart`. Related: `techx-corp-chart/docs/changes/2026-07-15-harden-pod-scheduling.md`. The chart must be rendered and its Critical-MNG headroom checked before the infra policy is promoted; neither repository requires an application API change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No application API change; Pending stateless pods gain more eligible Karpenter families. |
| **Infrastructure** | Changes desired EC2NodeClass/NodePool policy after an approved Terraform apply; no resources were applied in this change. |
| **Deployment** | Requires development plan/apply and bake before a separately approved production promotion. |
| **Performance** | Broader capacity categories can reduce Spot provisioning delays; no quantified latency claim is made before runtime evidence. |
| **Security** | Removes floating AMI selection and validates a bounded category/alias contract; no credentials or secret values are introduced. |
| **Reliability** | Adds explicit expiry and drain deadline; forced termination remains possible after `1h`. |
| **Cost** | Keeps per-pool CPU `32` and memory `64Gi` limits; `r` instances may have a higher unit price but are selected only within the existing capacity caps. |
| **Backward compatibility** | Terraform inputs have defaults; existing callers remain compatible, but the desired EC2NodeClass/NodePool templates change. |
| **Observability** | Runbook gates are documented; live alerting is a separate chart change. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Module formatting | `terraform fmt -check -recursive modules\karpenter` | ✅ Pass |
| Development formatting | `terraform fmt -check -recursive environments\development` | ✅ Pass |
| Production formatting | `terraform fmt -check -recursive environments\production` | ✅ Pass |
| Development validation | `terraform -chdir=environments\development validate` after backend-disabled, lockfile-read-only init | ✅ Configuration valid |
| Production validation | `terraform -chdir=environments\production validate` after backend-disabled, lockfile-read-only init | ✅ Configuration valid |
| Negative input guards | Refresh-disabled, lock-free plans with explicit invalid `-var` values | ✅ Rejects production budget `2`, floating `@latest`, duplicate categories, and malformed expiry |
| Node-resource chart lint | `helm lint modules\karpenter\charts\node-resources` | ✅ Pass |
| Node-resource render | `helm template` with the environment policy values | ✅ Exact alias, lifecycle, categories, budgets, and taints rendered |

### Manual Verification

* Read-only live inspection confirmed EC2NodeClass release `v20260709` before pinning it.
* Render inspection confirmed both Spot and On-Demand NodePools use `c`, `m`, and `r`, `expireAfter: 720h`, and `terminationGracePeriod: 1h`.
* Terraform dependencies were initialized locally with `-backend=false -lockfile=readonly`; no backend or Terraform state was accessed and no lockfile changed.
* Negative, refresh-disabled Terraform plan probes were run only to exercise input validation; no plan artifact was saved and no apply was performed.
* The production probe exposed an unrelated proposed removal of existing EKS plan-role access resources before the invalid budget diagnostic. No action was taken; any future production plan must resolve or explicitly preserve those access resources before approval.
* No Kubernetes mutation, Helm mutation, or AWS mutation was performed.

### Remaining Verification (Post-Merge)

* Operator: initialize the approved backend using the repository procedure and review saved Terraform plans for replacement or unexpected drift.
* Operator: resolve the unrelated EKS plan-role access-resource destroy diff observed during the validation probe; do not apply this Karpenter change while that diff remains.
* Operator: apply development only after approval; create a fresh NodeClaim and bake it for 24 hours.
* Operator: run a representative 30-minute scale-out/scale-in test, including Spot fallback and Pending-pod checks.
* Operator: promote production only after development evidence passes and a separate production plan is approved.

## Migration or Deployment Notes

1. Confirm the live CRDs and Karpenter controller are healthy with read-only commands.
2. Commit a temporary `"0"`/`"0"` disruption-budget freeze before changing AMI or lifecycle policy.
3. From the relevant environment directory, initialize and produce a saved Terraform plan using the repository's backend procedure; obtain immediate approval before any state-changing command.
4. Reject a plan that replaces the critical MNG, selects a floating AMI, or changes resources outside the declared Karpenter scope.
5. Apply development, validate the new NodeClaim, then bake for 24 hours and test representative scaling for at least 30 minutes.
6. Restore the Spot budget to `"1"`, observe for 60 minutes, then restore On-Demand to `"1"` and observe again.
7. Repeat the freeze and reviewed-plan sequence for production only after development acceptance.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Pinned AMI is incompatible with a workload | Low | High | Bake a new development NodeClaim for 24 hours; revert to the previously reviewed exact alias, never `@latest`. |
| Both per-pool budgets disrupt concurrently | Low | Medium | Freeze both at `"0"` during policy changes and reopen pools sequentially. |
| Forced expiry conflicts with a long PDB block | Medium | Medium | Observe PDB allowed disruptions; revert lifecycle values through Terraform before the `1h` deadline becomes unsafe. |
| New `r` category increases unit cost | Medium | Low | Existing CPU/memory NodePool caps remain; review NodeClaims and cost evidence after the bake. |
| Spot capacity remains unavailable | Medium | Medium | On-Demand fallback remains enabled with lower weight. |

**Rollback procedure:**

1. Commit a `"0"`/`"0"` disruption-budget freeze, review its saved Terraform plan, and obtain immediate approval before applying it.
2. Confirm destination capacity, Critical-MNG headroom, and PDB allowed disruptions before reverting the NodePool template.
3. Revert the environment and module policy in Git while retaining an exact previously reviewed AMI alias; never restore `@latest`.
4. Review the development rollback plan, obtain immediate approval, apply it, and verify NodePool, NodeClaim, and workload health.
5. Reopen Spot to `"1"`, observe for 60 minutes, then reopen On-Demand to `"1"` and observe again.
6. Repeat the frozen, reviewed-plan procedure in production only after development acceptance. Do not use direct mutating kubectl or Helm commands.

<!-- Change trail: @hungxqt - 2026-07-15 - Record pinned Karpenter lifecycle and disruption policy hardening. -->
