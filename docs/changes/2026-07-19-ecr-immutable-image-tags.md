# Change: ECR immutable image tags for all service repositories

## Summary

All TechX ECR service repositories now use **IMMUTABLE** image tags by default. The ECR module default changed from `MUTABLE` to `IMMUTABLE`, and both development and production environment stacks pass `ecr_image_tag_mutability = "IMMUTABLE"` so every nested service repo under `techx-dev-corp/*` and `techx-prod-corp/*` rejects retagging of existing tags after Terraform apply.

## Context

Mutable tags allow an existing tag (for example `sha-abc` or `v1.2.3`) to be overwritten with a different image digest. That weakens supply-chain guarantees: a digest that was scanned, signed, or promoted can be replaced without a new tag. Platform and secure-delivery plans already call for immutable runtime tags; this change makes that the infrastructure default for every catalog repository.

* Why now: harden the image contract so publish and promote always use unique tags.
* Related plans: workspace `docs/plan/2026-07-17-mandate-10-secure-delivery-pipeline.md` (D3 IMMUTABLE).
* Constraint: platform CI still pushes a movable registry cache tag `:buildcache` (`docker-bake.hcl`). Under IMMUTABLE, overwriting that tag fails until cache is moved off retaggable ECR tags.

## Before

* `modules/ecr` defaulted `image_tag_mutability` to **`MUTABLE`**.
* Environment stacks did not pass mutability into the module; both envs inherited MUTABLE for all service repos.
* Checkov note described mutability as optional per env (MUTABLE for dev).

## After

* Module default: **`IMMUTABLE`**, with validation allowing only `MUTABLE` or `IMMUTABLE`.
* New env variable `ecr_image_tag_mutability` (default `IMMUTABLE`) wired through development and production `main.tf`.
* Both `terraform.tfvars` sets: `ecr_image_tag_mutability = "IMMUTABLE"`.
* Per-service override still possible via `ecr_repository_overrides.<service>.image_tag_mutability` if a break-glass is required.
* Lifecycle policy comments document that movable `:buildcache` retags are incompatible with IMMUTABLE.

## Technical Design Decisions

* **IMMUTABLE for all repos (dev + prod)** rather than prod-only: same image contract in both environments; fewer surprises when promoting pipelines.
* **Plain `IMMUTABLE`** (not `IMMUTABLE_WITH_EXCLUSION`): the stack pins `hashicorp/aws` to `~> 5.0`, which does not provide exclusion-filter support (that landed in provider v6.8+). Avoided a provider major bump for this change.
* **Still allow `MUTABLE` via variable/override**: emergency rollback path without a code revert, but defaults stay immutable.
* **Did not change platform bake in this repo**: cache strategy is owned by `techx-corp-platform`; operators must fix or stage that before apply if CI still rewrites `:buildcache`.

## Implementation Details

1. Set `modules/ecr` `image_tag_mutability` default to `IMMUTABLE` and added value validation.
2. Added `ecr_image_tag_mutability` to development and production environment variables (default `IMMUTABLE`, same validation).
3. Passed `image_tag_mutability = var.ecr_image_tag_mutability` into `module "ecr"` in both environments.
4. Set `ecr_image_tag_mutability = "IMMUTABLE"` in both environment tfvars.
5. Updated ECR lifecycle comments and Checkov skip rationale for the new default.

## Files Changed

**Module:**
* `modules/ecr/variables.tf` — Default `image_tag_mutability` to IMMUTABLE; validation.
* `modules/ecr/main.tf` — Comment that IMMUTABLE blocks overwriting `:buildcache`.

**Environments:**
* `environments/development/variables.tf` — Added `ecr_image_tag_mutability`.
* `environments/development/main.tf` — Pass mutability into ECR module.
* `environments/development/terraform.tfvars` — `ecr_image_tag_mutability = "IMMUTABLE"`.
* `environments/production/variables.tf` — Added `ecr_image_tag_mutability`.
* `environments/production/main.tf` — Pass mutability into ECR module.
* `environments/production/terraform.tfvars` — `ecr_image_tag_mutability = "IMMUTABLE"`.

**Tooling / docs:**
* `.checkov.yaml` — Updated CKV_AWS_51 skip comment for IMMUTABLE default.
* `docs/changes/2026-07-19-ecr-immutable-image-tags.md` — This change record.

## Dependencies and Cross-Repository Impact

* **`techx-corp-platform`:** `docker-bake.hcl` pushes `${IMAGE_NAME}/<service>:buildcache` with registry cache `mode=max`. After IMMUTABLE apply, a second push of the same `:buildcache` tag will fail. Before or immediately after apply, move BuildKit cache to GitHub Actions cache (or unique cache tags / a separate mutable cache repo). Runtime tags that are already unique (`sha-*`, `v*`) remain valid.
* **`techx-corp-chart`:** No change. Helm continues to pin a version tag; immutability strengthens that pin.
* Related: N/A in other repos for this infra-only change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No pod runtime change after apply; only image push semantics change |
| **Infrastructure** | All ECR service repositories in dev and prod become tag-immutable after Terraform apply |
| **Deployment** | Terraform apply required on development and production; platform CI may fail on `:buildcache` rewrite until cache strategy is updated |
| **Performance** | No direct impact; CI may rebuild more layers if registry cache rewrite stops working |
| **Security** | Higher integrity: existing tags cannot be swapped to a different digest |
| **Reliability** | Safer rollbacks and promotions (tag always means one digest); CI breakage risk until cache is fixed |
| **Cost** | No material cost change (lifecycle policies unchanged) |
| **Backward compatibility** | Breaking for any workflow that retags the same string (especially `:buildcache` and any floating `latest`) |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Variable validation | Review of `contains(["MUTABLE", "IMMUTABLE"], ...)` | ✅ Present on module and env vars |
| Terraform apply | Not run (state-changing; requires operator approval) | ⏳ Pending |

### Manual Verification

* Confirmed module default, env wiring, and both tfvars set `IMMUTABLE`.
* Confirmed no other ECR repository resources outside `modules/ecr` define tag mutability for the service catalog.

### Remaining Verification (Post-Merge)

1. Plan and apply development, then production (or both via approved CI):

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/development plan -out=tfplan
REM review image_tag_mutability changes on aws_ecr_repository.this[*]
terraform -chdir=environments/production plan -out=tfplan
```

2. After apply, confirm one repo:

```cmd
aws ecr describe-repositories --repository-names techx-dev-corp/frontend --query "repositories[0].imageTagMutability"
```

Expected: `IMMUTABLE`.

3. Run a platform image publish and confirm runtime tags still push; if `:buildcache` fails, switch cache strategy in platform before relying on registry cache.

## Migration or Deployment Notes

1. **Preferred order:** fix platform BuildKit cache so it does not overwrite a fixed ECR tag, **then** apply this Terraform change. If apply happens first, expect the next bake’s `cache-to` for `:buildcache` to fail until platform is updated.
2. Apply development stack, smoke a single-service bake if needed, then production.
3. Do not use floating tags (`latest`) for deploy; continue with unique version tags already used by CI (`sha-*` / `v*`).
4. Emergency only: set `ecr_image_tag_mutability = "MUTABLE"` in the affected env tfvars and re-apply (or per-repo override).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Platform CI fails rewriting `:buildcache` | High | Medium | Move cache to GHA / unique tags before or right after apply |
| Operator retag workflow fails | Low | Medium | Use new unique tags; do not retag |
| Need temporary mutable tags | Low | Low | Set `ecr_image_tag_mutability = "MUTABLE"` and re-apply |

**Rollback procedure:**

1. Set `ecr_image_tag_mutability = "MUTABLE"` in the target environment `terraform.tfvars` (or revert this change).
2. Plan and apply the environment stack so `aws_ecr_repository` resources return to MUTABLE.
3. Restore platform cache behavior if it was changed independently.

<!-- Change trail: @hungxqt - 2026-07-19 - Document ECR IMMUTABLE image tags for all service repositories. -->
