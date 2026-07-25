# Change: Development Environment Creates ECR Only (Match Production Settings)

## Summary

The development Terraform stack (`environments/development`) now provisions **only nested ECR repositories**. All non-ECR modules (VPC, EKS, Argo CD, Secrets Manager/ESO, Mem0 RDS, AI model storage, Karpenter, Cluster Autoscaler, CloudFront, Client VPN, Sigstore policy-controller IRSA) were removed. ECR module inputs and lifecycle settings **match production** exactly; only the project path segment remains development-specific (`techx-dev-corp`).

## Context

* Operators need a minimal development infra surface for image publish CI (platform → ECR) without standing up a full EKS/VPC stack in the development environment.
* Production already defines the desired ECR catalog, mutability, scan, lifecycle, and cosign-artifacts override; development must use the same contract.
* Existing remote state may still reference removed resources; apply will plan destroys for those objects.

## Before

* `environments/development` mirrored a near-full production operational model: VPC, EKS, Argo CD, secrets, Karpenter, CA, optional CloudFront/VPN, Mem0, AI storage, and policy-controller IAM, plus ECR.
* ECR settings already largely matched production (`IMMUTABLE`, keep 5 / buildcache 0, `scan_on_push=false`, cosign override).
* Providers included `aws`, `tls`, `helm`, and `kubernetes` (EKS-dependent).

## After

* Development root module wires **only** `module.ecr` with the same argument set as production `module.ecr`.
* Variables and tfvars are limited to `aws_region`, `project_name`, `tags`, and `ecr_*`.
* Outputs are limited to ECR repository URLs/ARNs/names, image base URL, and service names.
* Provider config requires only the AWS provider and the existing S3 backend key `development/terraform.tfstate`.
* `docs/DEPLOYMENT.md` documents the ECR-only development scope and state-migration risk.

### ECR settings (exact match production except project path)

| Setting | Development | Production |
|---|---|---|
| `ecr_project_name` | `techx-dev-corp` | `techx-prod-corp` |
| `ecr_naming_mode` | `nested` | `nested` |
| `ecr_image_tag_mutability` | `IMMUTABLE` | `IMMUTABLE` |
| `ecr_keep_last_n_images` | `5` | `5` |
| `ecr_keep_last_n_buildcache` | `0` | `0` |
| `ecr_scan_on_push` | `false` | `false` |
| `ecr_force_delete` | `true` | `true` |
| cosign-artifacts override | MUTABLE, keep 1000, force_delete false | same |

## Technical Design Decisions

* **Remove non-ECR modules rather than feature-flag them:** development should not accidentally re-create expensive cluster resources from defaults.
* **Keep identity path `techx-dev-corp`:** platform CI and chart still expect a separate development registry project from `techx-prod-corp`.
* **Do not change the ECR module** (`modules/ecr`): production and development both use the shared default service catalog.
* **Drop kubernetes/helm/tls providers:** no longer referenced; simplifies CI validate/init.
* **Docs elsewhere (Karpenter, CA, Client VPN) still mention development historically:** those runbooks remain valid for production and for any future reintroduction; DEPLOYMENT development table is the source of truth for current scope.

## Implementation Details

1. Replaced `environments/development/main.tf` with a single `module "ecr"` block (same arguments as production).
2. Slimmed `variables.tf` and `terraform.tfvars` to identity + ECR settings only; copied production ECR values for lifecycle/mutability/overrides.
3. Slimmed `outputs.tf` to ECR outputs only.
4. Slimmed `provider.tf` to AWS provider + S3 backend.
5. Updated `docs/DEPLOYMENT.md` development constants and Bước 3 notes (ECR-only + destroy risk).
6. Recorded this change document.

## Files Changed

**Environment (development):**
* `environments/development/main.tf` — ECR-only root module.
* `environments/development/variables.tf` — ECR + identity variables only.
* `environments/development/terraform.tfvars` — ECR settings match production; drop VPC/EKS/etc.
* `environments/development/outputs.tf` — ECR outputs only.
* `environments/development/provider.tf` — AWS-only providers.
* `environments/development/.terraform.lock.hcl` — Provider lock refreshed after dropping kubernetes/helm/tls (aws only).

**Documentation:**
* `docs/DEPLOYMENT.md` — Development scope is ECR-only; migration caution.
* `docs/changes/2026-07-25-dev-env-ecr-only.md` — This change record.

Change trail exception for `environments/development/.terraform.lock.hcl`: machine-managed dependency lockfile; do not insert hand-edited trail comments.

## Dependencies and Cross-Repository Impact

* **techx-corp-platform:** continues to push to `techx-dev-corp/*` via bootstrap GHA ECR role; no code change required if image base remains the same.
* **techx-corp-chart:** GitOps for a development EKS cluster is **out of scope** of this environment until a cluster is provisioned elsewhere or modules are reintroduced.
* Bootstrap OIDC/ECR push roles are unchanged (still under `bootstrap/`).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No direct app code change. Dev image registry path unchanged (`techx-dev-corp`). |
| **Infrastructure** | Development Terraform no longer manages VPC/EKS/Karpenter/Argo/secrets/etc. Next apply destroys those resources if still in state. |
| **Deployment** | `terraform apply` in development only creates/updates nested ECR repos. |
| **Performance** | N/A |
| **Security** | Smaller blast radius for development apply credentials (ECR only). Policy-controller IRSA removed from this stack. |
| **Reliability** | No managed development cluster from this stack. |
| **Cost** | Removes ongoing cost of development VPC/NAT/EKS/etc. once destroyed. ECR storage remains. |
| **Backward compatibility** | Outputs other than `ecr_*` are removed; any consumer of former outputs (VPC/EKS/role ARNs) breaks. |
| **Observability** | No development control-plane log wiring from this stack. |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform -chdir=environments/development fmt -check -diff` | ✅ Pass |
| Init (no backend) | `terraform -chdir=environments/development init -backend=false` | ✅ Pass (refreshed lockfile to aws-only) |
| Validate | `terraform -chdir=environments/development validate` | ✅ Pass |

### Manual Verification

* Diff ECR block in `environments/development/terraform.tfvars` against production `ecr_*` block (only `ecr_project_name` / comments differ).
* Plan against remote state and confirm only ECR keeps/creates and former modules destroy (if present) — **not run** (state-changing risk; operator apply path).

### Remaining Verification (Post-Merge)

* Operator: `terraform -chdir=environments/development plan` against live state; review destroys before apply.
* Confirm platform CI can still push to `techx-dev-corp/*`.

## Migration or Deployment Notes

1. Ensure backend is configured (`environments/development/backend.hcl` from example).
2. Plan and **carefully review destroy set** if prior full stack exists in state:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/development init -backend-config=backend.hcl
terraform -chdir=environments/development plan -out=dev-ecr-only.tfplan
```

3. Apply only after approval of the destroy plan:

```cmd
terraform -chdir=environments/development apply "dev-ecr-only.tfplan"
```

4. Capture `ecr_image_base_url` for platform GitHub environment if needed:

```cmd
terraform -chdir=environments/development output ecr_image_base_url
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Accidental destroy of live development EKS/VPC still in state | High if state was full stack | High | Review plan; take state backups; reintroduce modules from git history if cluster must remain |
| Consumers of removed outputs fail | Medium | Medium | Update callers to ECR-only outputs or restore modules |
| ECR settings drift from production later | Low | Medium | Keep both tfvars ECR blocks in sync in future PRs |

**Rollback procedure:**

1. Restore previous `environments/development/{main,variables,outputs,provider,terraform.tfvars}.tf` from git.
2. `terraform init` / `plan` / `apply` to recreate the full stack (may require manual recovery if AWS resources were destroyed).

<!-- Change trail: @hungxqt - 2026-07-25 - Document development ECR-only stack matching production settings. -->
