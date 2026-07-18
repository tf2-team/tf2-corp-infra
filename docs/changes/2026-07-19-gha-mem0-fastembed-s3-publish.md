# Change: Grant platform GHA roles S3 publish for Mem0 FastEmbed

## Summary

Platform CI uses the same OIDC role as ECR push (`techx-gha-platform-prod` / `…-dev`) to publish Mem0 FastEmbed archives, but that role only had ECR permissions. Mem0 pods then failed `fetch-mem0-fastembed` with S3 `403 HeadObject` because the AI models bucket had no FastEmbed objects (IRSA GetObject without ListBucket returns 403 for missing keys). Bootstrap now attaches least-privilege S3 List/Get/Put on the Mem0 FastEmbed prefix in each environment AI models bucket.

## Context

Live production diagnosis (2026-07-19):

* Deploy pulls: `s3://techx-prod-tf2-ai-models-…/fastembed/paraphrase-multilingual-MiniLM-L12-v2/sha-033949b/<archive>`
* IRSA `techx-prod-tf2-mem0-model-read` correctly allows `s3:GetObject` on that prefix
* Bucket listed only `protectai/…` objects — **zero** `fastembed/` keys
* Admin `HeadObject` → 404; IRSA path → 403 (no ListBucket)
* GHA role `techx-gha-platform-prod` inline policy was ECR-only

## Before

* `modules/github-actions-ecr` only managed ECR push policy
* Bootstrap did not grant any AI-models S3 write to platform CI roles

## After

* Optional S3 publish inputs on `github-actions-ecr` (`s3_publish_*`)
* Bootstrap wires prod/dev AI models bucket + prefix `fastembed/paraphrase-multilingual-MiniLM-L12-v2/*` (matches chart + IRSA)

## Technical Design Decisions

* **Chosen:** extend existing GHA ECR OIDC role (same `AWS_ROLE_ARN` the FastEmbed job already assumes) rather than a second role.
* **Chosen:** hard-code env bucket names in bootstrap using the established `${project_name}-ai-models-${account_id}` contract to avoid remote-state dependency from bootstrap → env stacks.
* **Rejected:** open write to entire AI models bucket — only the Mem0 FastEmbed prefix.

## Implementation Details

1. Added optional S3 policy statements to `modules/github-actions-ecr`.
2. Bootstrap `local.github_actions_ecr_roles` includes publish ARNs for prod and dev buckets.
3. No environment-stack change required for runtime IRSA (already correct).

## Files Changed

**Modules:**
* `modules/github-actions-ecr/main.tf` — Optional S3 publish role policy.
* `modules/github-actions-ecr/variables.tf` — `s3_publish_*` inputs + validation.

**Bootstrap:**
* `bootstrap/main.tf` — Wire Mem0 FastEmbed publish ARNs for prod/dev GHA roles.

**Documentation:**
* `docs/changes/2026-07-19-gha-mem0-fastembed-s3-publish.md` — This change record.

## Dependencies and Cross-Repository Impact

* **techx-corp-platform:** Set `MEM0_FASTEMBED_ARTIFACT_S3_URI` to the chart `s3Prefix` (same FastEmbed path). Rebuild/publish FastEmbed for the live image tag (or one-time operator upload).
* **techx-corp-chart:** No change; URI layout already correct.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Enables CI to create objects the Mem0 init can GetObject |
| **Infrastructure** | Inline IAM policy on two GHA roles |
| **Security** | Prefix-scoped List/Get/Put only; no delete-all-bucket |
| **Deployment** | Requires bootstrap Terraform apply, then FastEmbed publish |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt/validate bootstrap | operator after edit | Pending apply machine |

### Manual Verification

* Confirmed empty FastEmbed prefix and ECR-only GHA policy in live AWS.

### Remaining Verification (Post-Merge)

1. `terraform -chdir=bootstrap plan` then apply (operator approval).
2. Set GitHub Environment `MEM0_FASTEMBED_ARTIFACT_S3_URI`.
3. Run platform publish so objects appear under `…/fastembed/…/${VERSION}/`.
4. Restart Mem0 pods; init fetch succeeds.

## Migration or Deployment Notes

1. Apply **bootstrap** Terraform (not env stack) after merge.
2. One-time operator upload is still valid for the current image tag if CI is not ready:

```cmd
cd /d techx-corp-platform
python src\mem0\scripts\build_embedding_model_artifact.py --output-dir %TEMP%\mem0-fastembed
aws s3 cp %TEMP%\mem0-fastembed\ ^
  s3://techx-prod-tf2-ai-models-493499579600/fastembed/paraphrase-multilingual-MiniLM-L12-v2/sha-033949b/ ^
  --recursive --exclude "*" --include "*.tar.gz" --include "*.sha256" --include "manifest.json" ^
  --region us-east-1
```

3. GitHub variable (production):

```text
MEM0_FASTEMBED_ARTIFACT_S3_URI=s3://techx-prod-tf2-ai-models-493499579600/fastembed/paraphrase-multilingual-MiniLM-L12-v2
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Bucket rename breaks ARN pin | Low | Medium | Align with env `project_name` contract |
| Over-broad prefix write | Low | Medium | Limited to FastEmbed path only |

**Rollback procedure:**

1. Remove `s3_publish_*` wiring / destroy the inline `…-s3-model-publish` policies via Terraform.
2. Re-apply bootstrap.

<!-- Change trail: @hungxqt - 2026-07-19 - Document GHA S3 publish for Mem0 FastEmbed. -->
