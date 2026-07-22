# Change: ECR lifecycle keep zero buildcache; align cosign keep to 5

## Summary

ECR lifecycle policy now keeps **0** `:buildcache`-tagged images (expire after 1 day), retains a maximum of **5** images per service repository, and keeps **1000** artifacts in the shared **`cosign-artifacts`** repository in both development and production.

## Context

Registry build-cache tags (`:buildcache`) grow storage and compete with deployable image retention. Operators requested buildcache retention of **0** while keeping runtime (and other) images capped at **5**. Cosign uses a **shared** mutable repo (`COSIGN_REPOSITORY=…/cosign-artifacts`) with **3** artifacts per signed service (sign + SBOM + provenance), so its keep count must be much higher than per-service image keep.

* Prior design kept **1** buildcache digest via `imageCountMoreThan` (see `2026-07-11-ecr-keep-one-buildcache.md`).
* `cosign-artifacts` previously overrode lifecycle to keep last **2000** images; briefly set to **5**, then set to **1000** as a shared-repo bound with headroom over ~`services × 5 × 3`.
* AWS ECR does not allow `countNumber = 0` for `imageCountMoreThan` or `sinceImagePushed`; the minimum is **1**.

## Before

* Module default / env tfvars: `keep_last_n_buildcache = 1`, `keep_last_n_images = 5`.
* Lifecycle rule 1: `tagPrefixList = ["buildcache"]`, `countType = imageCountMoreThan`, `countNumber = 1`.
* Lifecycle rule 2: `tagStatus = any`, keep last **5** images (service repos).
* `ecr_repository_overrides.cosign-artifacts.keep_last_n_images = 2000`.
* Module validation required `keep_last_n_buildcache >= 1`.

## After

* Module default / env tfvars: `keep_last_n_buildcache = 0`, `keep_last_n_images = 5`.
* When buildcache keep is **0**: rule 1 uses `sinceImagePushed` / `days` / `countNumber = 1` so buildcache tags older than **1 day** expire (most aggressive AWS-supported policy for that prefix).
* When buildcache keep is **>= 1**: previous `imageCountMoreThan` keep-N behavior is unchanged.
* Rule 2 still keeps last **5** images (any tag) for service repos.
* `cosign-artifacts` override: `keep_last_n_images = 1000`; still `MUTABLE`, `scan_on_push = false`, `force_delete = false`.
* Validation allows `keep_last_n_buildcache >= 0`.

## Technical Design Decisions

* **Age-based expire for keep 0:** AWS rejects `countNumber = 0`. `sinceImagePushed` with 1 day is the strongest legal way to drain buildcache tags without affecting non-buildcache retention logic.
* **Dual `jsonencode` branches:** Avoid Terraform object type mismatch between selection maps (age rule has `countUnit`; count rule does not).
* **Images remain at 5:** Already configured in both env tfvars; left explicit and documented.
* **Cosign keep 1000 (shared repo):** One cosign repo holds sign + SBOM + provenance for all services. Base need is roughly `~21 × 5 × 3 ≈ 315`; **1000** is a generous bound (above ~500 optimized) so admission/provenance survive full bakes and retries without the old **2000** over-provisioning. Cosign mutability and force-delete exceptions stay as before.

Alternatives considered:

| Alternative | Why not |
|---|---|
| Drop the buildcache rule entirely when 0 | Buildcache digests would only be cleaned by the any-tag rule and would consume the 5 runtime slots |
| Keep `imageCountMoreThan` with count 1 labeled as “0” | Still retains one buildcache image permanently |
| Cosign keep = 5 (match image keep) | Unsafe: shared repo would retain only 5 artifacts fleet-wide |
| Leave cosign at 2000 | Over-provisioned vs ~315 base need; operator chose **1000** |
| Force-delete via API outside lifecycle | Not declarative; outside Terraform desired state |

## Implementation Details

1. Extended `modules/ecr` lifecycle policy to branch on `keep_last_n_buildcache == 0`.
2. Relaxed module validation to `>= 0`; default **0**.
3. Set development and production `ecr_keep_last_n_buildcache = 0` (images remain **5**).
4. Set `cosign-artifacts.keep_last_n_images = 1000` in both env tfvars (shared cosign artifact pool).
5. Updated env variable descriptions/defaults and `docs/COST.md` keep counts.

## Files Changed

**Module:**
* `modules/ecr/main.tf` — Dual-path lifecycle policy for buildcache keep 0 vs keep N.
* `modules/ecr/variables.tf` — Default/validation for `keep_last_n_buildcache`.

**Environments:**
* `environments/development/terraform.tfvars` — `ecr_keep_last_n_buildcache = 0`; cosign keep **1000**.
* `environments/development/variables.tf` — Default/description for buildcache keep.
* `environments/production/terraform.tfvars` — `ecr_keep_last_n_buildcache = 0`; cosign keep **1000**.
* `environments/production/variables.tf` — Default/description for buildcache keep.

**Documentation:**
* `docs/COST.md` — ECR keep counts (5 runtime + 0 buildcache for both envs).
* `docs/changes/2026-07-22-ecr-buildcache-keep-zero.md` — This change record.

## Dependencies and Cross-Repository Impact

* **`techx-corp-platform`:** None required. If CI still pushes `:buildcache`, those tags expire after ~1 day under this policy. Runtime tags (`sha-*`, `v*`) are unaffected. Cosign sign/attest pushes still target `…/cosign-artifacts`; excess artifacts expire once count exceeds **1000**.
* **`techx-corp-chart`:** None.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change |
| **Infrastructure** | ECR lifecycle policies updated on service and cosign repos after apply |
| **Deployment** | Terraform apply required for development and production |
| **Performance** | Slightly less registry cache reuse if CI still relies on ECR `:buildcache` older than 1 day |
| **Security** | Cosign still MUTABLE; signature/attestation history bounded at keep-last **1000** in shared repo |
| **Reliability** | Runtime keep-last **5** unchanged; buildcache no longer permanently retained; cosign pool sized for multi-service sign+attest |
| **Cost** | Lower ECR storage (no long-lived buildcache; cosign keep **1000** vs prior **2000**) |
| **Backward compatibility** | Fully backward-compatible for deployable tags; buildcache retention reduced to age-based 1 day; cosign history capped at **1000** |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform format | `terraform fmt -check` on touched paths | Pending operator |
| Module validate | `terraform -chdir=modules/ecr` not standalone; env validate after init | Pending apply pipeline |

### Manual Verification

After apply, inspect a service repo and cosign repo:

```cmd
aws ecr get-lifecycle-policy ^
  --repository-name techx-dev-corp/checkout ^
  --query lifecyclePolicyText --output text

aws ecr get-lifecycle-policy ^
  --repository-name techx-dev-corp/cosign-artifacts ^
  --query lifecyclePolicyText --output text
```

Expect (service repo):

* Rule priority **1**: `tagPrefixList` includes `buildcache`, `countType` **sinceImagePushed**, `countNumber` **1**, `countUnit` **days**.
* Rule priority **2**: `tagStatus` **any**, `countNumber` **5**.

Expect (cosign-artifacts):

* Rule priority **2** (any-tag keep): `countNumber` **1000**.

### Remaining Verification (Post-Merge)

1. Apply development, then production (or via Terraform CI promote path).
2. Confirm lifecycle text as above; allow up to 24h for ECR to expire excess buildcache and cosign artifacts.
3. Optional: list images and confirm buildcache tags disappear after the age window; cosign count trends toward ≤1000.

## Migration or Deployment Notes

1. Merge this change in `techx-corp-infra`.
2. Plan/apply **development**, then **production** (or follow existing promote workflow).
3. No chart or platform image-tag changes required for the keep-5 runtime rule.
4. Lifecycle expiration is asynchronous; old buildcache digests and excess cosign artifacts may remain until ECR evaluates the policy.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| CI rebuilds slower without long-lived ECR buildcache | Medium | Low | Move cache to GHA cache / unique tags; or temporarily set `ecr_keep_last_n_buildcache = 1` |
| Operators expect instant delete of all buildcache | Medium | Low | Document 1-day age floor (AWS API limit) |
| Cosign signatures expire while corresponding service images still exist | Low | Medium | Keep **1000** >> base need (~315); raise if catalog or artifacts-per-image grows |
| Accidental tighten of runtime keep | Low | Medium | Runtime keep remains **5**; review plan JSON |

**Rollback procedure:**

1. Set `ecr_keep_last_n_buildcache = 1` in both env tfvars (or previous value).
2. Optionally restore `cosign-artifacts.keep_last_n_images = 2000` if longer signature history is required.
3. Re-apply environments so lifecycle policies return to the prior counts.

<!-- Change trail: @hungxqt - 2026-07-22 - ECR buildcache 0, images keep 5, cosign keep 1000. -->
