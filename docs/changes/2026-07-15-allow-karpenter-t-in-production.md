# Change: Allow Karpenter T-Series in Production

## Summary

Production Karpenter NodePools may now select burstable Graviton **t** instances (primarily `t4g.*` under arm64) in addition to **c**, **m**, and **r**. The shared module validation was widened so `t` is a legal category; development remains on `c`/`m`/`r` only.

## Context

* Production is operated as a cost-sensitive environment where Spot diversity and lower list-price capacity matter.
* The critical MNG floor already uses `t4g.*`; allowing **t** on Karpenter extends the same family to elastic capacity without dropping non-burstable families.
* Prior policy (2026-07-15 harden) locked categories to `c`/`m`/`r` to avoid T-only credit risk and thin Spot pools. This change **adds** `t` rather than returning to T-only.

## Before

* Module and production validation accepted only `c`, `m`, `r`.
* Production `terraform.tfvars` set `karpenter_instance_categories = ["c", "m", "r"]`.
* Docs described both environments as `c`/`m`/`r`.

## After

* Module `instance_categories` validation accepts `c`, `m`, `r`, **t** (default remains `["c", "m", "r"]`).
* Production variable default and tfvars are `["c", "m", "r", "t"]`.
* Development env validation and tfvars stay `c`/`m`/`r` only (no change to intended dev posture).
* Operator docs record the production vs development category split.

## Technical Design Decisions

* **Add t, do not replace c/m/r:** keeps non-burstable Spot/OD options when T credits or T Spot capacity are poor.
* **Production-only enablement:** development continues without `t` so the cheaper floor + non-burstable elastic split remains explicit until deliberately changed.
* **Rejected:** production T-only — reintroduces sustained-CPU throttling and thinner Spot diversity without fallback families.
* **Rejected:** listing explicit `t4g.medium` etc. — category-level selection remains Karpenter best practice within the allow-list.

## Implementation Details

1. Widened `modules/karpenter` `instance_categories` validation to include `t`.
2. Widened production `karpenter_instance_categories` validation and default to include `t`.
3. Set production `terraform.tfvars` to `["c", "m", "r", "t"]`.
4. Updated `docs/karpenter.md`, `docs/workload-placement.md`, and `docs/cpu-architecture.md`.
5. Recorded this change document.

## Files Changed

**Module:**

* `modules/karpenter/variables.tf` — Allow `t` in `instance_categories` validation; clarify description.

**Production environment:**

* `environments/production/variables.tf` — Allow and default `c`/`m`/`r`/`t`.
* `environments/production/terraform.tfvars` — Set categories to include `t`.

**Documentation:**

* `docs/karpenter.md` — Prod default column and module note.
* `docs/workload-placement.md` — Lifecycle row for prod categories.
* `docs/cpu-architecture.md` — Karpenter family table.
* `docs/changes/2026-07-15-allow-karpenter-t-in-production.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart and platform placement remain `workload-class` based; no image or AMI change is required beyond existing arm64 Graviton pairing for `t4g`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No pod API change; new NodeClaims may land on `t4g.*` when Karpenter chooses them |
| **Infrastructure** | Production NodePool instance-category allow-list expands to include `t` |
| **Deployment** | Requires reviewed Terraform plan/apply of production (or promote workflow); NodePool CR update via Helm node-resources chart |
| **Performance** | Possible burstable credit throttling if Karpenter packs sustained CPU work onto T instances |
| **Security** | No change |
| **Reliability** | Slightly broader Spot capacity; T interruptions/credits remain risks mitigated by retaining c/m/r |
| **Cost** | Expected lower or equal Spot/OD unit cost when T is selected |
| **Backward compatibility** | Fully backward-compatible; existing c/m/r selections remain valid |
| **Observability** | No new metrics; continue watching NodeClaim types and CPU steal/throttling |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt | `terraform fmt -check` on touched `.tf`/`.tfvars` | ✅ Pass |
| Terraform validate (prod) | `terraform -chdir=environments/production init -backend=false` then `validate` | ✅ Pass |

### Manual Verification

* Inspect production plan after apply path: NodePool requirements should list `karpenter.k8s.aws/instance-category` values including `t`.
* After apply, optional:

```cmd
kubectl get nodepool -o yaml
kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool
```

### Remaining Verification (Post-Merge)

1. Save and review production Terraform plan (no unexpected replacements beyond NodePool requirement update).
2. Apply via normal promote/review path (not break-glass kubectl).
3. Observe new NodeClaims for at least one scale event; confirm instance types may include `t4g.*` and still include non-T when better.
4. Watch for sustained CPU credit exhaustion under load-gen or dense packing.

## Migration or Deployment Notes

1. Merge this infra change; do **not** mutate NodePools with kubectl.
2. Freeze disruption budgets only if co-shipping other NodePool template changes; category expansion alone is usually low risk.
3. Plan/apply production stack with existing backend and OIDC roles.
4. Post-apply: confirm NodePool status and that pending pods still schedule.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Sustained CPU credit exhaustion on T nodes | Medium | Medium | Retain c/m/r; remove `t` from prod tfvars if throttling appears |
| Unexpected preference for small T over larger efficient instances | Low | Low | Karpenter still sizes from pod requests; review NodeClaim history |
| Spot T scarcity in AZ | Low | Low | c/m/r remain eligible; On-Demand fallback pool still present |

**Rollback procedure:**

1. Set production `karpenter_instance_categories = ["c", "m", "r"]` in `terraform.tfvars` (and optionally restore variable default).
2. Plan/apply production; NodePools drop `t` from requirements.
3. Existing T NodeClaims drain via normal consolidation/expiry or manual cordon after workload move — do not force-delete unless approved.

<!-- Change trail: @hungxqt - 2026-07-15 - Allow production Karpenter instance category t with c/m/r. -->
