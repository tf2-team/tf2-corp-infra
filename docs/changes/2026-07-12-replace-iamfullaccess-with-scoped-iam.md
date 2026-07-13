# Change: Replace IAMFullAccess with prefix-scoped custom IAM

## Summary

GitHub Actions Terraform **apply** roles no longer attach AWS managed `IAMFullAccess`. They keep `PowerUserAccess` for non-IAM APIs and gain an inline custom IAM policy limited to role/policy/instance-profile name prefixes used by environment stacks (plus OIDC providers and service-linked roles). This resolves Checkov `CKV2_AWS_56` without a global skip.

## Context

Checkov / Prisma `CKV2_AWS_56` failed on:

* `module.github_actions_terraform["development-apply"].aws_iam_role_policy_attachment.managed["arn:aws:iam::aws:policy/IAMFullAccess"]`
* `module.github_actions_terraform["production-apply"].aws_iam_role_policy_attachment.managed["arn:aws:iam::aws:policy/IAMFullAccess"]`

`IAMFullAccess` was an intentional bootstrap trade-off so env stacks could create EKS/IRSA/ALB/Karpenter IAM. Security policy requires least privilege instead of the AWS managed full IAM policy.

## Before

* Apply roles: `PowerUserAccess` + `IAMFullAccess` + prefix-scoped S3/KMS state policy.
* Plan roles: `ReadOnlyAccess` + state policy.
* Docs described apply as PowerUser + IAMFullAccess.

## After

* Apply roles: `PowerUserAccess` + **inline** `*-terraform-iam` policy + state policy.
* Custom IAM is scoped by `iam_name_prefixes` (module input; bootstrap defaults):
  * development: `["techx-dev"]` (matches `cluster_name = "techx-dev"`)
  * production: `["techx-tf2-prod"]` (matches `cluster_name = "techx-tf2-prod"`)
* Allowed under those prefixes: manage roles, customer-managed policies, instance profiles; attach/detach policies; `iam:PassRole`.
* Also allowed: list/get IAM discovery APIs (`Resource=*`), read AWS managed policies, manage OIDC providers, create/delete service-linked roles under `aws-service-role/*`.
* Plan roles unchanged (no custom IAM write policy).
* Docs (`SETUP.md`, `CI_CD_GUIDE.md`) updated; no Checkov global skip for `CKV2_AWS_56`.

## Technical Design Decisions

* **Custom policy over skip:** Prefer fixing the finding over suppressing `CKV2_AWS_56`.
* **Name-prefix scope (not path `/`):** Existing modules name roles as `{cluster_name}-…` without a shared IAM path. Prefix ARNs match that reality.
* **Keep PowerUserAccess:** Non-IAM services (VPC, EKS, ECR, ASG, etc.) remain covered by the managed policy; only IAM was over-broad.
* **OIDC providers not name-prefixed:** EKS OIDC issuer ARNs are URL-based; allow `oidc-provider/*` for account-level IRSA provider lifecycle.
* **Service-linked roles:** EKS/ELB/Auto Scaling create SLRs; grant `iam:CreateServiceLinkedRole` (and delete status) on `role/aws-service-role/*` only.
* **List/Get `Resource=*`:** AWS does not resource-level those discovery APIs; inline `# checkov:skip=CKV_AWS_356` with justification (same pattern as cluster-autoscaler).
* **Not in scope:** Removing PowerUserAccess; per-action fine lists for EC2/EKS; restricting OIDC provider ARNs to a single issuer string without coupling bootstrap to live cluster state.

## Implementation Details

1. `modules/github-actions-terraform`: drop `IAMFullAccess` from `managed_policy_arns`; add `iam_name_prefixes` variable; add `data.aws_iam_policy_document.terraform_iam` + `aws_iam_role_policy.terraform_iam` for apply only; assert apply has non-empty prefixes.
2. Bootstrap variables/objects: optional `iam_name_prefixes` with defaults `techx-dev` / `techx-tf2-prod`; pass into module for apply keys only.
3. `terraform.tfvars` / `.example`: document prefixes aligned with env `cluster_name`.
4. Docs: permission tables no longer mention `IAMFullAccess`.

## Files Changed

**Module:**

* `modules/github-actions-terraform/main.tf` — Custom IAM policy; remove managed IAMFullAccess.
* `modules/github-actions-terraform/variables.tf` — `iam_name_prefixes`.
* `modules/github-actions-terraform/outputs.tf` — export prefixes.

**Bootstrap:**

* `bootstrap/main.tf` — Pass `iam_name_prefixes`.
* `bootstrap/variables.tf` — Object fields + validation.
* `bootstrap/terraform.tfvars.example` — Documented defaults.
* `bootstrap/terraform.tfvars` — Workspace values for current cluster names.

**Documentation:**

* `docs/SETUP.md` — Permission table.
* `docs/CI_CD_GUIDE.md` — OIDC permission table + note.
* `docs/changes/2026-07-12-replace-iamfullaccess-with-scoped-iam.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Platform / chart:** None.
* **Operators:** After merge, run bootstrap **plan/apply** so apply roles detach `IAMFullAccess` and create `*-terraform-iam` inline policies. If env `cluster_name` changes, update `iam_name_prefixes` in bootstrap tfvars first.
* **CI:** Expect `CKV2_AWS_56` to pass for these resources once the attachment is gone.

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Application behavior** | None |
| **Infrastructure** | Apply role IAM permissions narrowed; bootstrap apply updates two roles |
| **Deployment** | Bootstrap apply required before next env apply that creates new IAM names outside previous full access (already covered if prefixes match cluster names) |
| **Performance** | None |
| **Security** | Removes full IAM user/group/account admin surface; no IAM writes outside configured prefixes (except OIDC + SLRs) |
| **Reliability** | Apply can fail with AccessDenied if modules introduce IAM names outside prefixes — fix by extending `iam_name_prefixes` |
| **Cost** | None |
| **Backward compatibility** | Existing roles named under current cluster prefixes remain manageable; hand-named IAM outside prefixes is no longer writable by CI |
| **Observability** | None |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
| --- | --- | --- |
| Bootstrap validate | `terraform -chdir=bootstrap init -backend=false` + `validate` | ✅ Pass |
| Format | `terraform fmt -check` on bootstrap + module | ✅ Pass (or applied) |
| Checkov CKV2_AWS_56 | `checkov -d modules/github-actions-terraform --check CKV2_AWS_56` | Run after change (expect no IAMFullAccess attachment) |

### Manual Verification

* Confirm env IAM resource names match prefixes:
  * Dev: `techx-dev-cluster-role`, `techx-dev-alb-controller-role`, …
  * Prod: `techx-tf2-prod-…`
* Bootstrap plan should show: detach `IAMFullAccess`, create/update `*-terraform-iam` inline policies on apply roles.

### Remaining Verification (Post-Merge)

1. `terraform -chdir=bootstrap plan` against live state.
2. Apply bootstrap.
3. Promote Dev / Production apply path that creates or updates IRSA roles (EKS/ESO/Karpenter) to confirm no IAM AccessDenied.
4. Re-run Checkov in CI.

## Migration or Deployment Notes

1. Ensure `iam_name_prefixes` in bootstrap match each env `cluster_name` (defaults already set for current tfvars).
2. Apply bootstrap.
3. No GitHub secret changes (role ARNs unchanged).
4. If a future module uses an IAM name outside the prefix, either rename the resource to use `cluster_name` or add another prefix entry.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
| --- | --- | --- | --- |
| Missing IAM action for a rare Terraform call | Medium | Medium | Expand custom policy statements; re-apply bootstrap |
| Wrong/missing `iam_name_prefixes` | Low (defaults match tfvars) | High | Plan review; align with `cluster_name` |
| OIDC provider `*` still broad within IAM | Accepted | Medium | Account has few OIDC providers; tighter binding needs live cluster URL in bootstrap |
| PowerUser still broad for non-IAM | Unchanged | Medium | Future work; out of this change |

**Rollback procedure:**

1. Revert this change.
2. Bootstrap apply to re-attach `IAMFullAccess` if still required.
3. Keep state prefixes and OIDC trust as-is.
