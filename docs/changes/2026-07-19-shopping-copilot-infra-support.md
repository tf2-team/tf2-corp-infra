# Change: Shopping Copilot infrastructure support (platform PR #36)

## Summary

Add infrastructure contracts required by platform Shopping Copilot and the AI release path: nested ECR repository `shopping-copilot`, AWS Secrets Manager shell for LLM credentials, and a dedicated ProtectAI model-read IRSA consumer that shares the existing guardrail prefix with `product-reviews`.

## Context

Platform PR [#36](https://github.com/tf2-team/tf2-corp-platform/pull/36) introduces `src/shopping-copilot` (gRPC + LangGraph), wires it in Compose, and reuses product-reviews guardrails/grounding. Mem0 ECR, RDS, FastEmbed S3 publish, and related IRSA already exist in this repository. Without a matching ECR catalog entry, platform image publish cannot push `…/shopping-copilot:<tag>` after bake release is enabled. Without ASM + bootstrap and model IRSA, chart cutover cannot inject `OPENAI_API_KEY` or download ProtectAI weights for the new ServiceAccount.

* Why now: unblock platform PR #36 follow-up (bake release + chart enablement).
* Constraint: no secret values in Terraform state; multi-service reuse of the same ProtectAI S3 prefix.

## Before

* `modules/ecr` default `services` listed 22 bake services including `mem0` / `llm` but **not** `shopping-copilot`.
* ASM shells included `product-reviews` and `mem0` but no shopping-copilot shell.
* `ai-model-storage` consumers: `product-reviews` (ProtectAI) and `mem0` (FastEmbed) only; validation required **distinct** `model_prefix` per consumer.
* Bootstrap scripts wrote `OPENAI_API_KEY` only to `…/product-reviews`.
* `docs/DEPLOYMENT.md` ECR catalog list omitted `mem0` and `shopping-copilot`.

## After

* ECR catalog includes `shopping-copilot` → nested repos `techx-*-corp/shopping-copilot` (dev and prod project names).
* ASM secret shell `…/shopping-copilot` (metadata only; values via bootstrap).
* Dev and prod `ai_model_storage` consumers include `shopping-copilot` SA with ProtectAI prefix and `allow_list_bucket = true`, separate IRSA role from `product-reviews`.
* Module allows shared `model_prefix` across consumers; SA pair uniqueness still enforced.
* Bootstrap PowerShell/bash put the same `OPENAI_API_KEY` env into the new shell (independent rotation still possible via separate put later).
* Deployment catalog docs list `mem0` and `shopping-copilot`.

## Technical Design Decisions

* **Separate ASM shell** vs reusing `product-reviews`: independent chart ExternalSecret and key rotation; same JSON shape (`OPENAI_API_KEY`) for operational simplicity.
* **Shared ProtectAI prefix, separate IRSA roles**: shopping-copilot reuses the same offline guardrail weights already published for product-reviews; distinct roles keep blast radius and SA trust isolation. Dropped “unique prefix per consumer” validation as that blocked this pattern without duplicating multi-GB artifacts.
* **No chart changes in this repo**: chart ESO target, Deployment IRSA annotation, and `shopping-copilot.enabled` remain chart/GitOps work.
* **No new RDS / Valkey / Kafka**: cart pending tokens use existing commerce Valkey; catalog/reviews are in-cluster gRPC.

## Implementation Details

1. Appended `shopping-copilot` to `modules/ecr` default `services` and added module test.
2. Added `shopping-copilot` to `modules/secrets-manager` secret key set and module test.
3. Relaxed `modules/ai-model-storage` prefix uniqueness validation; wired consumers in development and production; extended consumer isolation test.
4. Updated `scripts/bootstrap-asm-secrets.{ps1,sh}` to put `OPENAI_API_KEY` into the new shell.
5. Updated `docs/DEPLOYMENT.md` ECR service list.
6. Recorded this change document.

## Files Changed

**Modules:**
* `modules/ecr/variables.tf` — Catalog `shopping-copilot`.
* `modules/ecr/tests/shopping_copilot.tftest.hcl` — Nested repo + scan-on-push asserts.
* `modules/secrets-manager/main.tf` — ASM shell key `shopping-copilot`.
* `modules/secrets-manager/tests/shopping_copilot.tftest.hcl` — Metadata-only secret asserts.
* `modules/ai-model-storage/variables.tf` — Allow shared model prefixes.
* `modules/ai-model-storage/tests/mem0_consumers.tftest.hcl` — Shopping Copilot IRSA + shared ProtectAI asserts.

**Environments:**
* `environments/development/main.tf` — `shopping-copilot` model consumer.
* `environments/production/main.tf` — `shopping-copilot` model consumer.

**Scripts:**
* `scripts/bootstrap-asm-secrets.ps1` — Put `OPENAI_API_KEY` to shopping-copilot shell.
* `scripts/bootstrap-asm-secrets.sh` — Same for bash.

**Documentation:**
* `docs/DEPLOYMENT.md` — ECR catalog list includes mem0 + shopping-copilot.
* `docs/changes/2026-07-19-shopping-copilot-infra-support.md` — This change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-platform (PR #36):** Still must add `shopping-copilot` to `docker-bake.hcl` release group and CI release JSON so publish actually targets the new ECR repo. Infra alone does not publish images.
* **techx-corp-chart (follow-up):**
  * ExternalSecret → K8s Secret from ASM `…/shopping-copilot` (`OPENAI_API_KEY`).
  * ServiceAccount annotation with IRSA role from `ai_model_consumer_role_arns["shopping-copilot"]`.
  * Init container / S3 URI for ProtectAI prefix (same objects as product-reviews).
  * Component values for deployment when enabling the service.
* Related platform work: cart/user-id binding and bake release gaps remain platform-side (not infra).

Write `None` only if fully self-contained — **not** the case here.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change until chart deploys shopping-copilot and platform publishes the image |
| **Infrastructure** | +1 ECR repo per env project; +1 ASM secret shell per env; +1 IRSA role/policy per env |
| **Deployment** | Env Terraform apply required before chart enablement; bootstrap put-secret after shell exists |
| **Performance** | Negligible (metadata/IAM only) |
| **Security** | Least-privilege IRSA for new SA; secret values stay outside TF state |
| **Reliability** | Unblocks image push destination; model download path ready for chart |
| **Cost** | Empty ECR + ASM shells negligible; IRSA free; no new always-on data plane |
| **Backward compatibility** | Existing product-reviews/mem0 consumers unchanged |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform test (ECR) | `terraform -chdir=modules/ecr init -backend=false` then `test` | Pass (2) |
| Terraform test (secrets) | `terraform -chdir=modules/secrets-manager init -backend=false` then `test` | Pass (2) |
| Terraform test (ai-model-storage) | `terraform -chdir=modules/ai-model-storage init -backend=false` then `test` | Pass (1) |
| Fmt | `terraform fmt -check` on touched `.tf` paths | Pass |

### Manual Verification

* Not applied to live AWS in this change (approval-gated).

### Remaining Verification (Post-Merge)

1. Plan/apply **development** then **production** environment stacks (operator approval).
2. Confirm ECR: `aws ecr describe-repositories` shows `{project}/shopping-copilot`.
3. Confirm ASM shell exists; bootstrap:

```cmd
cd /d techx-corp-infra
scripts\bootstrap-asm-secrets.cmd techx-corp/development us-east-1
```

(Set real `OPENAI_API_KEY` in the environment before bootstrap for non-dummy values.)

4. Record IRSA ARN:

```cmd
terraform -chdir=environments/development output -json ai_model_consumer_role_arns
```

5. Chart PR uses that ARN + ExternalSecret remote key `…/shopping-copilot`.
6. Platform bake/publish must include shopping-copilot before cluster pull succeeds.

## Migration or Deployment Notes

1. **Order:** infra env apply → bootstrap ASM value → platform image publish to new ECR → chart ExternalSecret + Deployment → Argo sync.
2. ProtectAI objects need **not** be re-uploaded if already present under `protectai/deberta-v3-base-prompt-injection-v2/` for product-reviews.
3. Do not enable shopping-copilot in chart until image tags exist in ECR for the target environment.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Chart enables service before image exists | Medium | Medium | Keep chart disabled until ECR tags verified |
| Shared ProtectAI prefix over-permission | Low | Low | Separate IRSA; still prefix-scoped GetObject (+ List when allowed) |
| Bootstrap overwrites product-reviews and shopping-copilot with same key | Low | Low | Intentional default; rotate shells independently later |

**Rollback procedure:**

1. Revert this Terraform change and apply (destroys empty ECR only if `force_delete` allows; prefer leave empty repo).
2. Remove chart references first if already wired.
3. Optional: delete ASM secret after recovery window policy if unused.

<!-- Change trail: @hungxqt - 2026-07-19 - Infra support for platform shopping-copilot (ECR, ASM, IRSA). -->
