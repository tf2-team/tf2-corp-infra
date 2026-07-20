# Change: Bedrock IRSA foundation-model invoke via inference profiles

## Summary

Extend the `ai-model-storage` consumer IRSA policy so Bedrock `InvokeModel` is allowed not only on configured inference-profile ARNs but also on the derived foundation-model ARNs, conditioned on `bedrock:InferenceProfileArn`. This fixes production Shopping Copilot intent parsing failures caused by `AccessDeniedException` on `arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-2-lite-v1:0`.

## Context

Shopping Copilot in production uses IRSA role `techx-prod-tf2-shopping-copilot-model-read` with `BEDROCK_MODEL_ID=global.amazon.nova-2-lite-v1:0`. Runtime logs showed Converse failing because the role was not authorized for the **foundation model** resource Bedrock evaluates when routing through a system inference profile.

AWS Bedrock requires both:

1. Permission on the inference profile ARN passed as `modelId`
2. Permission on the underlying foundation model ARN(s) the profile routes to

Why now: unblock prod Shopping Copilot Bedrock intent parse after profile-only IAM was applied.

## Before

* `InvokeBedrockInferenceProfiles` allowed `bedrock:GetInferenceProfile` and `bedrock:InvokeModel` only on:
  * `arn:aws:bedrock:<region>:<account>:inference-profile/<profile-id>`
* No foundation-model resources were listed.
* Calling `global.amazon.nova-2-lite-v1:0` failed with AccessDenied on:
  * `arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-2-lite-v1:0`

## After

* Existing inference-profile statement unchanged.
* New statement `InvokeBedrockFoundationModelsViaProfiles` allows `bedrock:InvokeModel` on:
  * `arn:aws:bedrock:<region>::foundation-model/<model-id>`
  * `arn:aws:bedrock:::foundation-model/<model-id>` (global routing form)
* Foundation model ids are derived by stripping known system profile prefixes (`global.`, `us.`, `eu.`, `apac.`).
* Access is conditioned with `bedrock:InferenceProfileArn` equal to the consumer’s approved profile ARNs so direct foundation-model invokes remain denied.
* Consumer access contract output includes `bedrock_foundation_model_ids` for review and tests.

## Technical Design Decisions

* **Profile + conditioned foundation model** rather than broad `foundation-model/*`: matches AWS inference-profile prerequisites while keeping least privilege.
* **Derive model id from profile id** rather than a second consumer input list: avoids config drift between chart `BEDROCK_MODEL_ID` and IAM; supported prefixes cover current system profiles in use.
* **Include region-empty foundation-model ARN** for global profiles, per AWS global inference-profile examples.
* **No env `main.tf` changes**: prod/dev already pass `bedrock_inference_profile_ids = ["global.amazon.nova-2-lite-v1:0"]`; module-only fix is sufficient after apply.

## Implementation Details

1. Added `local.bedrock_foundation_model_ids` map keyed by consumer.
2. Extended `consumer_access_contracts` with `bedrock_foundation_model_ids`.
3. Added dynamic IAM statement `InvokeBedrockFoundationModelsViaProfiles` with `StringEquals` on `bedrock:InferenceProfileArn`.
4. Extended module test assertions for Nova foundation model derivation and empty list for non-Bedrock consumers.
5. Documented the Bedrock contract on the consumers variable description.

## Files Changed

**Modules:**
* `modules/ai-model-storage/main.tf` — Foundation-model InvokeModel statement + derivation locals.
* `modules/ai-model-storage/variables.tf` — Document profile/foundation IAM contract.
* `modules/ai-model-storage/tests/mem0_consumers.tftest.hcl` — Assert derived foundation model ids.

**Documentation:**
* `docs/changes/2026-07-20-bedrock-inference-profile-foundation-model-iam.md` — This change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-chart / techx-corp-platform:** None required. Chart already sets `BEDROCK_MODEL_ID=global.amazon.nova-2-lite-v1:0` and the prod ServiceAccount IRSA annotation.
* Operators must **apply** this module change in development and production so the live IAM policy updates. Code merge alone does not fix the running cluster.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Shopping Copilot Bedrock Converse / intent parse can succeed after IAM apply (assuming model access is enabled in the account) |
| **Infrastructure** | IRSA policy documents for Bedrock-enabled consumers gain a second statement |
| **Deployment** | Terraform apply of `ai-model-storage` in each environment |
| **Security** | Foundation models only invokable when request uses approved inference profile ARNs |
| **Reliability** | Removes IAM denial that aborted intent parsing |
| **Backward compatibility** | Additive policy; no role rename or trust change |
| **Cost** | No new resources; only IAM policy content |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Module test | `terraform -chdir=modules/ai-model-storage test` | ✅ Pass (1/1) |
| Fmt | `terraform fmt modules/ai-model-storage` | ✅ Clean |

### Manual Verification

* Compared denial resource `foundation-model/amazon.nova-2-lite-v1:0` with previous policy resources (inference-profile only).
* Confirmed derivation: `global.amazon.nova-2-lite-v1:0` → `amazon.nova-2-lite-v1:0`.

### Remaining Verification (Post-Merge)

1. Apply production (and development if needed) Terraform for `ai_model_storage`.
2. Confirm IAM policy on `techx-prod-tf2-shopping-copilot-model-read` includes foundation-model ARNs with `bedrock:InferenceProfileArn` condition.
3. Retry Shopping Copilot intent; logs should no longer show AccessDenied on foundation-model InvokeModel.

## Migration or Deployment Notes

1. Merge this change to `techx-corp-infra`.
2. Plan/apply the environment stack(s) that use `module.ai_model_storage` (development, production).
3. No chart redeploy or image rebuild required solely for this IAM fix.
4. IAM policy updates are eventually consistent; retry the failing request shortly after apply.

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
REM review plan, then after approval:
terraform -chdir=environments/production apply tfplan
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Condition key not present on some Bedrock paths | Low | Medium | Retry without condition only if AWS denies with unexpected resource; keep profile statement |
| Additional foundation ARNs needed for multi-region global routing | Low | Medium | Expand resources with required regional foundation-model ARNs if new denials appear |
| Broader model access than intended if wrong profile ids configured | Low | Medium | Consumers still pin explicit profile ids; condition binds FM invoke to those ARNs |

**Rollback procedure:**

1. Revert this module change and re-apply Terraform, or remove the `InvokeBedrockFoundationModelsViaProfiles` statement and apply.
2. Shopping Copilot Bedrock invokes will return to AccessDenied on foundation-model resources.

<!-- Change trail: @hungxqt - 2026-07-20 - Bedrock profile plus conditioned foundation-model IRSA for Shopping Copilot. -->
