# CI/CD Guide for Terraform Infrastructure

This repository uses GitHub Actions with AWS OIDC and Terraform S3 remote state.

## Workflows

| Workflow | File | Triggers | Purpose |
| --- | --- | --- | --- |
| **Terraform CI** | `terraform-ci.yml` | `pull_request` (path-filtered), `workflow_dispatch` | Format, validate, TFLint, Checkov (+ SARIF), dual-env plan with **safe** PR summaries |
| **Promote Dev** | `terraform-promote-dev.yml` | `push` to `main` (`environments/development/**`, `modules/**`, `.github/workflows/**`), `workflow_dispatch` | Plan + apply development |
| **Promote Production** | `terraform-promote-production.yml` | **`workflow_dispatch` only** (`plan_only` input) | Plan + apply production after human approval |
| **Terraform Drift Detection** | `terraform-drift.yml` | Weekdays `22:00` UTC cron, `workflow_dispatch` | Plan both envs; manage one drift issue per environment |
| **Terraform Destroy Dev** | `terraform-destroy-dev.yml` | `workflow_dispatch` (`confirm=destroy-dev`) | Destroy development after confirmation + Environment |
| **Terraform Destroy Production** | `terraform-destroy-production.yml` | `workflow_dispatch` (`confirm=destroy-production`) | Plan-then-approve production destroy |
| **Terraform Apply** (reusable) | `terraform-apply.yml` | `workflow_call` only | Shared plan → artifact → Environment-gated apply |

**Bootstrap** (`bootstrap/`) is validated in CI (fmt/validate) but is **not** auto-applied. Apply bootstrap out-of-band / manually. Bootstrap owns the S3 remote state backend **and** account-level GitHub Actions OIDC + platform ECR push roles (`techx-gha-platform-*`). Terraform **plan/apply** IAM roles for this repo remain operator-managed (see secrets table below).

## Operating model

1. Open a pull request for infrastructure changes.
2. Review static checks, Checkov, and **safe structural** Terraform plan summaries on the PR.
3. Merge to `main` → **Promote Dev** applies development (path-filtered).
4. Validate in development.
5. Run **Promote Production** manually (`workflow_dispatch`). Optional: `plan_only=true`.
6. Approve the `production` GitHub Environment gate; apply uses the **immutable** binary plan from the same run.

Module changes on `main` auto-apply **dev only**. Production never auto-applies on push.

## Safe plan summary policy

Public surfaces (PR comments, GitHub Job Summaries, drift issues, CI/drift artifacts) publish **only**:

- Add / change / delete / replace **counts**
- At most **200** resource **addresses** (escaped)
- Environment label

They **never** publish:

- Attribute values, before/after objects
- Output values
- Provider configuration
- Full human-readable plan text
- Raw plan JSON
- Binary `tfplan` (except apply/destroy-apply artifacts)

Renderer: `scripts/render-terraform-plan-summary.sh`  
Tests: `scripts/tests/render-terraform-plan-summary/run-tests.sh`

Binary Terraform plans can contain sensitive data ([HashiCorp plan file warning](https://developer.hashicorp.com/terraform/cli/commands/plan)). They are limited to apply-path artifacts with short retention.

## Artifact contracts

| Artifact | Contents | Retention | Used by |
| --- | --- | --- | --- |
| `terraform-apply-plan-<environment>` | Binary `tfplan` + safe `plan-summary.md` | **3 days** | Promote Dev / Production apply |
| `terraform-destroy-plan-production` | Binary `tfplan` + safe summary | **3 days** | Production destroy apply |
| `ci-plan-summary-<environment>` | Safe summary only | **7 days** | Terraform CI |
| `drift-summary-<environment>` | Safe summary only | **7 days** | Drift detection |
| `checkov-sarif` | `results.sarif` | **7 days** | Terraform CI |

## Concurrency

State-mutating and state-reading automation for an environment share one group (`cancel-in-progress: false`):

| Group | Workflows |
| --- | --- |
| `terraform-state-dev` | Promote Dev, Destroy Dev, Drift (dev) |
| `terraform-state-production` | Promote Production, Destroy Production, Drift (production) |

This prevents another promote/destroy/drift run from interleaving between plan and apply for the same environment.

Terraform CI uses `terraform-ci-<pr|ref>` with `cancel-in-progress: true` (no state write).

## Required GitHub secrets

Create these as **repository secrets** (plan/drift/PR jobs do not always attach a GitHub Environment). Apply roles may instead be Environment secrets if you want stricter ownership—names must match.

| Secret | Example |
| --- | --- |
| `DEV_AWS_PLAN_ROLE_ARN` | `arn:aws:iam::<account-id>:role/GitHubTerraformDevPlanRole` |
| `DEV_AWS_APPLY_ROLE_ARN` | `arn:aws:iam::<account-id>:role/GitHubTerraformDevApplyRole` |
| `DEV_TF_BACKEND_BUCKET` | `techx-tf-state-<account-id>-us-east-1` |
| `DEV_TF_BACKEND_REGION` | `us-east-1` |
| `DEV_AWS_REGION` | `us-east-1` |
| `PROD_AWS_PLAN_ROLE_ARN` | `arn:aws:iam::<account-id>:role/GitHubTerraformProdPlanRole` |
| `PROD_AWS_APPLY_ROLE_ARN` | `arn:aws:iam::<account-id>:role/GitHubTerraformProdApplyRole` |
| `PROD_TF_BACKEND_BUCKET` | `techx-tf-state-<account-id>-us-east-1` |
| `PROD_TF_BACKEND_REGION` | `us-east-1` |
| `PROD_AWS_REGION` | `us-east-1` |

## GitHub Environments

| Environment | Protection |
| --- | --- |
| `dev` | Optional approval; used by Promote Dev apply and Destroy Dev |
| `production` | **Required reviewers**; prevent self-review when the GitHub plan allows. Used by Promote Production apply and Destroy Production apply |

Environment approval runs before the protected job starts a runner. Confirmation phrases therefore run in a **separate unprotected job** so a wrong phrase never waits on reviewers or assumes AWS roles.

## Destroy flows

### Development

1. `workflow_dispatch` with `confirm` = exact string `destroy-dev`.
2. Unprotected validation job rejects mismatches (no checkout, no AWS, no Environment).
3. Environment `dev` job runs `terraform destroy -auto-approve`.

### Production

1. `workflow_dispatch` with `confirm` = exact string `destroy-production`.
2. Unprotected validation job rejects mismatches.
3. **destroy-plan** (plan role): `terraform plan -destroy -detailed-exitcode -out=tfplan`
   - Exit **1** → fail (no issue side effects elsewhere; no apply)
   - Exit **0** → success, **no** Environment approval, no apply
   - Exit **2** → upload immutable plan + safe summary; request apply
4. **destroy-apply** (`environment: production`, apply role): download artifact → `terraform apply` that plan only.

## Drift lifecycle

Exact issue title: `Terraform drift detected: <environment>`  
Labels: `terraform`, `drift`, `<environment>` (created if missing).

| Plan result | Behavior |
| --- | --- |
| Exit 2 (drift), no open issue | Create one issue with safe summary body |
| Exit 2, open issue exists | **Replace body** only (no extra comments) |
| Exit 0 (clean), open issue exists | One resolved comment + **close** issue |
| Exit 0, no open issue | No-op |
| Exit 1 (error) | Fail the job; **do not** create, close, or modify issues |

A later recurrence after close creates a **new** issue.

## Checkov and SARIF

- Checkov is a **required gate** (`soft_fail: false`).
- Outputs CLI + SARIF (`results.sarif`).
- Artifact `checkov-sarif` always attempted on success or failure.
- Code scanning upload is **best-effort** (`continue-on-error: true`) when Advanced Security / code scanning is unavailable.
- Workflow permission `actions: read` supports private-repository code-scanning upload compatibility.

## TFLint

- Config: `.tflint.hcl` — Terraform recommended preset + AWS ruleset **v0.48.0** (pinned).
- CI: `tflint --init` then `tflint --recursive --minimum-failure-severity=error`.
- Existing warnings may remain non-blocking; **new errors must be fixed**, not suppressed.

## AWS OIDC trust policy

Create an IAM OIDC provider for `https://token.actions.githubusercontent.com`, then create separate plan/apply roles for dev and production.

Production **apply** role trust should restrict the subject to the production GitHub Environment:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<github-org>/<github-repo>:environment:production"
        }
      }
    }
  ]
}
```

Dev apply subject:

```text
repo:<github-org>/<github-repo>:environment:dev
```

Plan roles are used by pull request and drift workflows. Scope their trust to the repository (and refs as appropriate); keep IAM permissions read-heavy. Apply roles carry write permissions and must be protected by GitHub Environments.

## Action pin maintenance

Third-party Actions are pinned to **full commit SHAs** with a trailing `# vN` comment matching the major tag used before the pin.

When updating an action:

1. Resolve the commit behind the desired **same major** tag (do not silently jump majors in routine maintenance).
2. Replace the SHA and keep the `# vN` comment accurate.
3. Re-run CI and `actionlint`.

Do not rely on floating tags (`@v4`) in workflows.

## Notes

- Terraform state locking uses S3 native lock files (`use_lockfile = true`).
- Backend bucket/region come from secrets; committed `backend.hcl` files are not required for CI.
- Fork pull requests skip the AWS plan job (no secrets to forks).
- Paths for development: `environments/development` (not a shortened alias).
