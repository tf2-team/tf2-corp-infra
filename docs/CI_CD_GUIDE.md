# CI/CD Guide for Terraform Infrastructure

This repository uses GitHub Actions with AWS OIDC and Terraform S3 remote state.

## Workflows

| Workflow | Purpose |
| --- | --- |
| `Terraform CI` | Runs on pull requests. Performs format, validate, TFLint, Checkov, and Terraform plan for dev and production. |
| `Promote Dev` | Runs on merge to `main` or manual dispatch. Applies `enviroments/dev`. |
| `Promote Production` | Runs manually. Uses the `production` GitHub Environment for approval before applying. |
| `Terraform Drift Detection` | Runs on a weekday schedule and opens an issue when Terraform detects drift. |

## Required GitHub Variables

Create plan role, backend, and region values as repository variables because pull request and drift jobs do not attach a GitHub Environment. Apply role values may be repository variables or matching GitHub Environment variables when you want stricter ownership.

| Variable | Example |
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

Create two GitHub Environments:

| Environment | Protection |
| --- | --- |
| `dev` | Optional approval. Good for automatic apply after merge. |
| `production` | Required reviewers enabled. Prevent self-review if possible. |

## AWS OIDC Trust Policy

Create an IAM OIDC provider for `https://token.actions.githubusercontent.com`, then create separate roles for dev and production.

The production apply role trust policy should restrict the subject to the production GitHub Environment:

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

For dev, use the `dev` environment subject:

```text
repo:<github-org>/<github-repo>:environment:dev
```

Plan roles are used by pull request and drift workflows. Scope their trust policy to the repository and main branch as appropriate, then keep the IAM permissions read-heavy. Apply roles should carry the write permissions and must be protected by GitHub Environments.

## Operating Model

1. Open a pull request for infrastructure changes.
2. Review static checks, security scan, and Terraform plans.
3. Merge to `main` to apply dev.
4. Run `Promote Production` manually after dev validation.
5. Review the production Environment approval gate.
6. Apply production from the immutable plan generated in the workflow run.

## Notes

- Terraform state is locked with S3 native lock files through `use_lockfile = true`.
- The workflows pass backend bucket and region through GitHub variables, so real `backend.hcl` files remain uncommitted.
- Production applies are serialized with workflow concurrency to prevent parallel state writes.
- Jobs that run `terraform init` use the composite action `.github/actions/setup-terraform-cached`, which caches provider plugins via `TF_PLUGIN_CACHE_DIR` (keyed on `**/.terraform.lock.hcl`). TFLint enables `cache: true` on `setup-tflint`.
