# Change: ECR lifecycle keep only one buildcache image

## Summary

ECR lifecycle policies now retain **one** `:buildcache`-tagged image per service repository, separately from the existing keep-last-N rule for runtime (and other) images. This stops registry build-cache digests from competing with deployable image retention and caps cache storage growth.

## Context

Platform CI (`docker-bake.hcl`) pushes a movable registry cache tag `${IMAGE_NAME}/<service>:buildcache` on every bake. Previously the ECR module had a single lifecycle rule (`tagStatus = any`, keep last N), so `buildcache` digests counted toward the same N as `sha-*` runtime tags. That wasted retention slots and could expire useful runtime history or leave stale cache layers.

* Why now: cost control and clearer retention for CI registry cache.
* Related prior change: `docs/changes/2026-07-10-dev-ecr-keep-last-5-images.md` (noted buildcache competition as a known limitation).

## Before

* `modules/ecr` lifecycle policy: one rule — expire when total image count exceeds `keep_last_n_images` (`tagStatus = any`).
* Development: keep last **5** images total per repo.
* Production: keep last **20** images total per repo.
* No separate treatment of the `buildcache` tag prefix.

## After

* Lifecycle policy has **two** rules (priority order):
  1. **Tagged prefix `buildcache`:** keep last `keep_last_n_buildcache` (default **1**).
  2. **Any remaining images:** keep last `keep_last_n_images` (dev **5**, prod **20**).
* Images matched by rule 1 are not re-evaluated by rule 2, so the latest build cache does not consume a runtime retention slot.
* Configurable via `keep_last_n_buildcache` (module) / `ecr_keep_last_n_buildcache` (environments); both env tfvars set to `1`.

## Technical Design Decisions

* **Separate tag-prefix rule** instead of lowering overall N further: preserves runtime history while explicitly capping cache.
* **Default keep 1 buildcache:** CI always overwrites `:buildcache`; only the latest cache artifact is needed for subsequent builds. Keeping more would only grow storage.
* **Kept `tagStatus = any` for rule 2** rather than only `sha-` prefixes so untagged intermediate layers still fall under the general count and age out.
* **Not** deleting all untagged immediately: aggressive untagged expiration can thrash shared cache layers mid-build; the dual-rule approach is sufficient for the stated goal.

## Implementation Details

1. Extended `modules/ecr` locals with `keep_last_n_buildcache` (global + per-repo override).
2. Replaced single lifecycle rule with rule priority 1 (`tagPrefixList = ["buildcache"]`) and rule priority 2 (existing any-tag keep-last-N).
3. Added module variable `keep_last_n_buildcache` (default `1`, validation `>= 1`).
4. Wired `ecr_keep_last_n_buildcache` through development and production environment variables, module calls, and tfvars.
5. Documented cost impact in `docs/COST.md`.

## Files Changed

**Module:**
* `modules/ecr/main.tf` — Dual-rule lifecycle policy; merge `keep_last_n_buildcache`.
* `modules/ecr/variables.tf` — New `keep_last_n_buildcache`; optional override on `repositories`.

**Environments:**
* `environments/development/main.tf` — Pass `keep_last_n_buildcache`.
* `environments/development/variables.tf` — `ecr_keep_last_n_buildcache` (default 1).
* `environments/development/terraform.tfvars` — `ecr_keep_last_n_buildcache = 1`.
* `environments/production/main.tf` — Pass `keep_last_n_buildcache`.
* `environments/production/variables.tf` — `ecr_keep_last_n_buildcache` (default 1).
* `environments/production/terraform.tfvars` — `ecr_keep_last_n_buildcache = 1`.

**Documentation:**
* `docs/COST.md` — ECR keep counts include 1 buildcache.
* `docs/changes/2026-07-11-ecr-keep-one-buildcache.md` — This change record.

## Dependencies and Cross-Repository Impact

None for code deploy. Platform CI continues to push `:buildcache` as before (`techx-corp-platform` `docker-bake.hcl`). No chart or platform repository changes required.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change; deploy tags (`sha-*`, etc.) unchanged |
| **Infrastructure** | ECR lifecycle policies updated on all service repos in both envs after apply |
| **Deployment** | Terraform apply required on development and production stacks |
| **Performance** | CI rebuilds still use latest `:buildcache`; only one cache tag retained |
| **Cost** | Lower ECR storage for stale build-cache digests |
| **Reliability** | Runtime image retention no longer shared with buildcache count |
| **Backward compatibility** | Fully compatible; only retention of older cache digests tightens |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt/validate | Run after edit in env dirs | Operator / local validate |

### Manual Verification

After apply, inspect one repo:

```bash
aws ecr get-lifecycle-policy \
  --repository-name techx-dev-corp/ad \
  --region us-east-1 \
  --query 'lifecyclePolicyText' --output text
```

Expect:
* Rule priority **1**: `tagPrefixList` includes `buildcache`, `countNumber` **1**.
* Rule priority **2**: `tagStatus` `any`, `countNumber` **5** (dev) or **20** (prod).

### Remaining Verification (Post-Merge)

1. `terraform plan` then `apply` in `environments/development`.
2. `terraform plan` then `apply` in `environments/production`.
3. Confirm lifecycle text as above; allow up to 24h for ECR to expire excess images.

## Migration or Deployment Notes

1. Apply **development** first (optional dry-run), then **production**.
2. Lifecycle expiration is asynchronous; excess `buildcache` digests are removed by ECR over time, not instantly on apply.
3. No application restart or chart upgrade required.
4. To keep more cache history temporarily, set `ecr_keep_last_n_buildcache` higher and re-apply.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Slightly colder CI rebuild if only one cache root is kept | Low | Low | Default matches “latest only” cache model; raise N if needed |
| Rule priority misconfiguration expires wrong tags | Low | Medium | Policy uses explicit `buildcache` prefix first; review plan JSON |

**Rollback procedure:**

1. Revert module lifecycle policy to a single `tagStatus = any` rule (or set `ecr_keep_last_n_buildcache` higher).
2. Re-apply the affected environment Terraform stack.
