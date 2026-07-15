# Change: Private S3 delivery for AI guardrail models

## Summary

Added environment-specific private S3 storage and workload identity so
`product-reviews` can load pinned prompt-injection model weights during pod
startup without embedding those weights in every application image.

## What Changed

- Added `modules/ai-model-storage` for development and production.
- Created one private, encrypted and versioned S3 bucket per environment.
- Added an S3 Gateway VPC endpoint to the EKS private route tables so model
  downloads do not require NAT or public internet routing.
- Added a dedicated IRSA role for the `product-reviews` ServiceAccount in each
  environment namespace.
- Restricted workload access to `GetObject` under the approved ProtectAI model
  prefix and `ListBucket` for that prefix only.
- Exported bucket, IRSA role and VPC endpoint identifiers for chart/bootstrap
  configuration.

## Security and Trust Boundaries

| Actor | Allowed action | Denied by design |
|---|---|---|
| `product-reviews` ServiceAccount | Read objects below `protectai/deberta-v3-base-prompt-injection-v2/` | Upload, overwrite, delete, read other prefixes |
| Artifact publisher | Upload through an operator/CI identity managed outside this module | Runtime pod does not inherit publisher permissions |
| Public/anonymous client | None | Public ACLs and public bucket policies are blocked |

The bucket policy denies non-TLS S3 requests. Server-side encryption uses
SSE-S3, and versioning provides recovery from accidental artifact replacement.
No model artifact or API key is stored in Terraform state or this repository.

## Files Changed

- `modules/ai-model-storage/main.tf` — S3, endpoint, least-privilege policy and IRSA role.
- `modules/ai-model-storage/variables.tf` — environment, VPC, OIDC and workload identity inputs.
- `modules/ai-model-storage/outputs.tf` — bucket, role, prefix and endpoint outputs.
- `modules/ai-model-storage/versions.tf` — Terraform and AWS provider constraints.
- `modules/vpc/outputs.tf` — private route table IDs used by the gateway endpoint.
- `environments/development/main.tf` and `outputs.tf` — development wiring.
- `environments/production/main.tf` and `outputs.tf` — production wiring.
- `docs/changes/2026-07-15-ai-guardrail-model-delivery.md` — this record.

## Cross-Repository Dependencies

- `tf2-corp-chart` configures the IRSA annotation and init container that
  downloads and verifies the artifact.
- `tf2-corp-platform` builds the pinned Hugging Face cache artifact and makes
  `product-reviews` fail startup when the required model is unavailable.
- AWS credentials, Terraform apply, artifact publication and Argo CD rollout
  remain operator-controlled actions.

## Deployment Order

1. Run format, validation and plan for the target Terraform environment.
2. Review and apply the infrastructure plan.
3. Build the model artifact from `tf2-corp-platform`.
4. Upload `model.tar.gz`, `model.tar.gz.sha256` and `manifest.json` to the exact
   revision prefix in the target environment bucket.
5. Confirm the chart S3 URI and IRSA ARN match Terraform outputs.
6. Merge/sync the chart, then deploy the platform image.

Upload the artifact separately to every environment before its chart is synced.
In particular, a development upload does not populate the production bucket.

## Validation

| Check | Status |
|---|---|
| Change-scoped `terraform fmt -check` | Passed with Terraform 1.10.5 container |
| `terraform validate` development | Passed with Terraform 1.10.5 container |
| `terraform validate` production | Passed with Terraform 1.10.5 container |
| `terraform plan` and policy review | Required before apply |
| Live S3 download through IRSA and gateway endpoint | Required after apply |

The existing repository-wide format check still reports
`modules/cost-budgets/main.tf`, which is outside this change and was not modified.

## Impact and Cost

- New resources per environment: one S3 bucket, one gateway endpoint, one IAM
  role and one customer-managed IAM policy.
- S3 Gateway Endpoints have no hourly endpoint charge; normal S3 storage and
  request charges apply.
- Pod startup gains an S3 download/extraction step. The application image becomes
  independent of model weight updates.

## Risks and Rollback

| Risk | Mitigation |
|---|---|
| Chart sync occurs before artifact upload | Upload and verify all three objects before sync; init container fails closed |
| IRSA subject or ARN mismatch | Compare Terraform outputs with chart namespace and ServiceAccount before merge |
| Artifact corruption | Init container checks SHA-256 and readiness marker before app startup |
| Existing unmanaged S3 endpoint conflicts | Import or reconcile the live endpoint before apply; do not force-create around state |

Rollback the chart first so pods stop depending on S3 delivery. The bucket is not
configured for force deletion; retain model artifacts until the application
rollback is verified, then remove infrastructure through a reviewed Terraform
plan.
