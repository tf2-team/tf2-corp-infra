# GitHub Setup for Terraform CI/CD

Operator runbook to enable the GitHub Actions Terraform pipelines in this repository.

For day-to-day workflow behavior (triggers, safe plan policy, drift lifecycle, destroy flows), see [`CI_CD_GUIDE.md`](./CI_CD_GUIDE.md). For end-to-end AWS bootstrap and environment stacks, see [`DEPLOYMENT.md`](./DEPLOYMENT.md).

## Placeholders

| Placeholder | Example |
| --- | --- |
| `<github-org>` | GitHub org or user that owns this repo |
| `<github-repo>` | Infra repository name on GitHub (may differ from local folder name) |
| `<account-id>` | AWS account ID (see `DEPLOYMENT.md`; example `493499579600`) |
| `<region>` | `us-east-1` |
| `<state-bucket>` | `techx-tf-state-<account-id>-us-east-1` |

---

## 0. Prerequisites (AWS first)

Complete these before GitHub secrets and Environments will work.

### 0.1 Bootstrap applied

Bootstrap must already exist (or be applied manually out-of-band). It owns:

- S3 remote state bucket + KMS
- GitHub OIDC provider for `token.actions.githubusercontent.com`
- Platform ECR push roles (`techx-gha-platform-*`) — used by **platform** CI, not this repo’s Terraform workflows
- **This repo’s** Terraform plan/apply roles (via `modules/github-actions-terraform`):

| Key | Default IAM role name | Used by |
| --- | --- | --- |
| `development-plan` | `GitHubTerraformDevPlanRole` | PR plan, drift (dev), promote plan |
| `development-apply` | `GitHubTerraformDevApplyRole` | Promote Dev apply, Destroy Dev |
| `production-plan` | `GitHubTerraformProdPlanRole` | PR plan, drift (prod), promote plan, destroy plan |
| `production-apply` | `GitHubTerraformProdApplyRole` | Promote Production apply, Destroy Production apply |

Configure the infra GitHub repository in `bootstrap/terraform.tfvars`:

```hcl
github_actions_terraform_development = {
  github_repository        = "<github-org>/<github-repo>"
  apply_github_environment = "dev"
  # defaults: plan/apply role names, plan_allowed_refs, plan_allow_pull_request, state_key_prefix
}

github_actions_terraform_production = {
  github_repository        = "<github-org>/<github-repo>"
  apply_github_environment = "production"
}
```

Apply bootstrap (manual / out-of-band — not auto-promoted by env CI):

```bash
terraform -chdir=bootstrap init -backend-config=backend.hcl
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply bootstrap.tfplan
terraform -chdir=bootstrap output
# Convenience map of all ten GitHub secret names → values:
terraform -chdir=bootstrap output -json github_actions_terraform_github_secrets
```

### 0.2 Role trust and permissions (created by Terraform)

Defaults match workflow Environment names and secret examples:

| Role | OIDC subjects (default) | Permissions |
| --- | --- | --- |
| Dev plan | `repo:…:pull_request`, `repo:…:ref:refs/heads/techx-dev-corp` | AWS `ReadOnlyAccess` + S3/KMS state under `development/` |
| Dev apply | `repo:…:environment:dev` | `PowerUserAccess` + prefix-scoped custom IAM (`iam_name_prefixes`, default `techx-dev`) + state under `development/` |
| Prod plan | `repo:…:pull_request`, `repo:…:ref:refs/heads/main` | `ReadOnlyAccess` + state under `production/` |
| Prod apply | `repo:…:environment:production` | `PowerUserAccess` + prefix-scoped custom IAM (default `techx-tf2-prod`) + state under `production/` |

Apply roles intentionally **do not** trust raw git refs — only GitHub Environments — so required reviewers can gate writes. Apply roles **do not** use AWS managed `IAMFullAccess` (Checkov `CKV2_AWS_56`); IAM writes are limited to role/policy/instance-profile names under `iam_name_prefixes` (aligned with env `cluster_name`), plus OIDC provider and service-linked role management needed by EKS modules.

State keys used by this repo:

| Environment | State key prefix |
| --- | --- |
| Development | `development/` (`development/terraform.tfstate`) |
| Production | `production/` (`production/terraform.tfstate`) |

If environment stacks pass `plan_role_arn` into the EKS module (access entry), set that variable to the corresponding plan role ARN from bootstrap outputs after roles exist.

### 0.3 Existing hand-created roles

If roles with the same names already exist outside Terraform, **import** them into bootstrap state before apply (see `docs/changes/2026-07-12-bootstrap-terraform-cicd-iam-roles.md`). Do not apply a create against an existing role name.

---

## 1. Repository settings (GitHub)

1. Open the **infra** GitHub repository that contains `.github/workflows/terraform-*.yml`.
2. Confirm the **dev integration branch** is **`techx-dev-corp`** (Promote Dev triggers on push to `techx-dev-corp`; production promote remains manual from `main` / dispatch).
3. **Settings → Actions → General**
   - Allow Actions workflows for this repository.
   - Workflow permissions: repository default may be read-only; workflows declare their own `permissions:` blocks (`pull-requests: write`, `issues: write`, `id-token: write`, etc.). Ensure org policy does not strip OIDC (`id-token`) or required write scopes for PR comments / drift issues.

---

## 2. Create GitHub Environments

**Settings → Environments → New environment**

### Environment: `dev`

| Setting | Value |
| --- | --- |
| Name | `dev` exactly (workflows use `environment: dev`) |
| Required reviewers | Optional for a lab; recommended for shared accounts |
| Deployment branches | Limit to `main` (recommended) |

Used by:

- Promote Dev → apply job
- Destroy Dev

### Environment: `production`

| Setting | Value |
| --- | --- |
| Name | `production` exactly |
| Required reviewers | **Yes** — add one or more reviewers |
| Prevent self-review | Enable when the GitHub plan allows |
| Wait timer | Optional |
| Deployment branches | Limit to `main` only |

Used by:

- Promote Production → apply
- Destroy Production → apply

Plan jobs intentionally **do not** use these Environments. Only apply / destroy-apply jobs do.

Environment approval is requested before a protected job starts a runner. Destroy confirmation phrases therefore run in a **separate unprotected job** so a wrong phrase never waits on reviewers or assumes AWS roles.

---

## 3. Create repository secrets

**Settings → Secrets and variables → Actions → New repository secret**

Create **all ten** secrets. Preferred source after bootstrap apply:

```bash
terraform -chdir=bootstrap output -json github_actions_terraform_github_secrets
```

| Secret | Source |
| --- | --- |
| `DEV_AWS_PLAN_ROLE_ARN` | Bootstrap output `DEV_AWS_PLAN_ROLE_ARN` |
| `DEV_AWS_APPLY_ROLE_ARN` | Bootstrap output `DEV_AWS_APPLY_ROLE_ARN` |
| `DEV_TF_BACKEND_BUCKET` | Bootstrap `state_bucket_name` |
| `DEV_TF_BACKEND_REGION` | Bootstrap region (`us-east-1`) |
| `DEV_AWS_REGION` | Same as backend region |
| `PROD_AWS_PLAN_ROLE_ARN` | Bootstrap output `PROD_AWS_PLAN_ROLE_ARN` |
| `PROD_AWS_APPLY_ROLE_ARN` | Bootstrap output `PROD_AWS_APPLY_ROLE_ARN` |
| `PROD_TF_BACKEND_BUCKET` | Same state bucket (keys differ by prefix) |
| `PROD_TF_BACKEND_REGION` | Same region |
| `PROD_AWS_REGION` | Same region |

Optional hardening: store **apply** role ARNs as **Environment secrets** on `dev` / `production` instead of repository secrets (names must stay the same). Plan and drift jobs still need plan role ARNs at **repository** secret level because those jobs do not always attach an Environment.

Committed `backend.hcl` files are not required for CI; bucket and region come from secrets.

---

## 4. Branch protection on `main`

**Settings → Branches → Add rule** for `main`:

Recommended:

- [x] Require a pull request before merging
- [x] Require status checks to pass  
  After the first CI run, select the job names that appear, for example:
  - Static checks (`bootstrap`, `environments/development`, `environments/production`)
  - TFLint
  - Checkov IaC scan
  - Plan dev / Plan production (same-repository PRs only)
- [x] Require branches to be up to date (optional but recommended)
- [x] Restrict who can push / bypass (as your org policy allows)

Fork pull requests skip the AWS plan job by design (no secrets to forks). Adjust required checks if you accept external forks.

---

## 5. Workflow inventory

After workflows exist on the default branch, **Actions** should list:

| Workflow | File | Trigger | Operator setup |
| --- | --- | --- | --- |
| Terraform CI | `terraform-ci.yml` | PR (path-filtered), `workflow_dispatch` | Branch protection |
| Promote Dev | `terraform-promote-dev.yml` | Push to `techx-dev-corp` (path-filtered), `workflow_dispatch` | Environment `dev` |
| Promote Production | `terraform-promote-production.yml` | **`workflow_dispatch` only** (`plan_only`) | Environment `production` |
| Terraform Drift Detection | `terraform-drift.yml` | Weekdays `22:00` UTC, `workflow_dispatch` | Issues permission (declared in workflow) |
| Terraform Destroy Dev | `terraform-destroy-dev.yml` | `workflow_dispatch` (`confirm=destroy-dev`) | Environment `dev` |
| Terraform Destroy Production | `terraform-destroy-production.yml` | `workflow_dispatch` (`confirm=destroy-production`) | Environment `production` |
| Terraform Apply (reusable) | `terraform-apply.yml` | `workflow_call` only | — |

Promote Dev path filters:

- `environments/development/**`
- `modules/**`
- `.github/workflows/**`

Production never auto-applies on push.

---

## 6. First verification (in order)

### 6.1 Static checks and plan (no apply)

1. Open a small pull request that touches `environments/development/**`, `modules/**`, or another path that triggers Terraform CI.
2. Confirm **Terraform CI** runs:
   - fmt / validate / TFLint / Checkov
   - Plan dev and Plan production (same-repo PR)
   - Sticky PR comments with **safe** summaries only (action counts + resource addresses; no attribute values)
3. Fix Checkov/TFLint **errors** before merge. Existing warnings may be non-blocking; do not suppress new errors.

### 6.2 Promote Dev

1. Merge the PR to `techx-dev-corp`, or run **Actions → Promote Dev → Run workflow**.
2. If Environment `dev` has required reviewers, approve the deployment.
3. Confirm OIDC assume succeeds and apply finishes green.
4. Spot-check AWS resources and job logs (`terraform output`).

### 6.3 Promote Production (manual)

1. **Actions → Promote Production → Run workflow**.
2. First run with **`plan_only = true`**:
   - Expect plan + artifact + safe summary
   - Apply job is skipped when `plan_only` is true
3. Second run with **`plan_only = false`**.
4. Approve the **production** Environment when prompted.
5. Confirm apply uses the uploaded immutable `tfplan` from the same run.

### 6.4 Drift detection

1. **Actions → Terraform Drift Detection → Run workflow**.
2. Clean plan → no issue (or closes an existing open drift issue for that environment).
3. If drift exists, expect an issue titled exactly:
   - `Terraform drift detected: dev`
   - `Terraform drift detected: production`

Labels: `terraform`, `drift`, and the environment name (`dev` or `production`).

### 6.5 Destroy (only when intentional)

| Environment | `confirm` input (exact) |
| --- | --- |
| Development | `destroy-dev` |
| Production | `destroy-production` |

Wrong phrase fails in the unprotected validation job (no checkout AWS role assume, no Environment wait).

Production destroy is **plan-then-approve**: destroy plan with plan role, then Environment-gated apply of the destroy plan with apply role. If the destroy plan has no changes, apply is skipped.

---

## 7. Day-to-day operating model

```text
1. PR → Terraform CI (static + dual-env plan + safe PR comment)
2. Merge to `techx-dev-corp` → Promote Dev auto-applies (path-filtered)
3. Validate in development
4. Actions → Promote Production (manual; optional plan_only)
5. Approve production Environment → apply immutable plan
```

- Production **never** auto-applies on push.
- Module changes on `main` auto-apply **development only**.
- Bootstrap remains manual / out-of-band.

---

## 8. Permissions checklist

| Need | Where |
| --- | --- |
| OIDC assume | Bootstrap IAM roles + OIDC provider |
| PR plan comments | Workflow `pull-requests: write` |
| Drift issues | Workflow `issues: write` |
| Checkov code scanning upload | Optional Advanced Security; upload is best-effort |
| Secrets available to workflows | Repository secrets from bootstrap outputs |
| Apply only from Environment | IAM `sub` = `…:environment:dev` / `…:environment:production` |

---

## 9. Common failures

| Symptom | Likely cause |
| --- | --- |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Wrong role ARN secret, wrong `github_repository` in bootstrap tfvars, or Environment name mismatch (`dev` vs `development`) |
| Plan works, apply fails OIDC | Apply role trust missing Environment subject; Environment name not `dev` / `production` |
| Backend init fails | Wrong `*_TF_BACKEND_BUCKET` / region, or role lacks S3/KMS on state prefix |
| PR has no AWS plan | Fork PR (by design) or missing plan role secrets |
| Promote Dev never runs | Path filter: only `environments/development/**`, `modules/**`, `.github/workflows/**` |
| Stuck on Environment | Required reviewer not approving; check the Deployments tab |
| Destroy fails immediately after wrong confirm | Expected — re-run with the exact confirmation phrase |

---

## 10. Minimal click path

1. **AWS:** Apply bootstrap (state + OIDC + ECR push roles + four Terraform plan/apply roles).
2. **GitHub Environments:** `dev`, `production` (required reviewers on production).
3. **Repository secrets:** all ten values from `github_actions_terraform_github_secrets`.
4. **Branch protection:** PR + required CI checks on `main`.
5. **Verify:** PR CI → merge / Promote Dev → Promote Production (`plan_only`, then real) → optional Drift.

---

## Related documents

| Document | Purpose |
| --- | --- |
| [`CI_CD_GUIDE.md`](./CI_CD_GUIDE.md) | Workflow inventory, safe plan policy, concurrency, secrets table, OIDC notes |
| [`DEPLOYMENT.md`](./DEPLOYMENT.md) | Bootstrap and environment stack deploy runbook |
| [`USAGE_GUIDE.md`](./USAGE_GUIDE.md) | Local Terraform usage patterns |
| [`changes/2026-07-12-bootstrap-terraform-cicd-iam-roles.md`](./changes/2026-07-12-bootstrap-terraform-cicd-iam-roles.md) | Implementation record for plan/apply roles in bootstrap |
