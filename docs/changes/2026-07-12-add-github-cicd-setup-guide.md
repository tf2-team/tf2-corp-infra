# Change: Add GitHub CI/CD SETUP guide

## Summary

Added `docs/SETUP.md`, an operator runbook for enabling this repository’s Terraform GitHub Actions pipelines: AWS prerequisites (bootstrap + plan/apply IAM roles), GitHub Environments, repository secrets, branch protection, first-run verification, and common failure modes.

## Context

The workflows and day-to-day operating model are documented in `docs/CI_CD_GUIDE.md`, but that guide assumes secrets, Environments, and IAM trusts already exist. Operators needed a single setup checklist to wire GitHub and AWS so CI, promote, drift, and destroy workflows can run successfully.

## Before

* `docs/CI_CD_GUIDE.md` described workflows, secrets names, Environment names, and OIDC trust examples.
* `docs/DEPLOYMENT.md` covered bootstrap and environment stack apply.
* No dedicated step-by-step GitHub enablement document existed under `docs/`.

## After

* `docs/SETUP.md` provides ordered setup instructions from AWS prerequisites through GitHub configuration and first verification.
* Cross-links to `CI_CD_GUIDE.md` and `DEPLOYMENT.md` for behavior vs deploy depth.

## Technical Design Decisions

* **Separate SETUP from CI_CD_GUIDE:** Keep “how workflows behave” distinct from “how to enable them once,” avoiding bloating the operating guide.
* **Operator-managed plan/apply roles remain out-of-band:** Matches current design (roles not Terraform resources in env stacks); SETUP documents trusts and secret names without inventing new automation.
* **Exact Environment names `dev` and `production`:** Matches workflow `environment:` values; called out to avoid confusion with AWS/env directory names (`development`).
* **No workflow or IAM code changes in this change:** Documentation only.

## Implementation Details

1. Wrote `docs/SETUP.md` covering:
   * Placeholders and AWS bootstrap prerequisites
   * Four Terraform plan/apply IAM roles and OIDC trust subjects
   * GitHub Environments, ten repository secrets, branch protection
   * Workflow inventory and path filters
   * First verification (CI → Promote Dev → Promote Production → Drift → Destroy notes)
   * Day-to-day model, permissions checklist, common failures
2. Added this change record under `docs/changes/`.

## Files Changed

**Documentation:**

* `docs/SETUP.md` — New GitHub + AWS operator setup runbook for Terraform CI/CD.
* `docs/changes/2026-07-12-add-github-cicd-setup-guide.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Platform and chart repositories are unchanged. Operators still configure plan/apply IAM in AWS and secrets/Environments in the infra GitHub repository.

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Application behavior** | None |
| **Infrastructure** | None (docs only; no Terraform resource changes) |
| **Deployment** | Clearer onboarding path for enabling infra CI/CD; no pipeline behavior change |
| **Performance** | None |
| **Security** | Documents recommended OIDC Environment-scoped apply trusts; does not weaken existing controls |
| **Reliability** | None |
| **Cost** | None |
| **Backward compatibility** | N/A |
| **Observability** | None |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
| --- | --- | --- |
| N/A | Documentation-only change | N/A |

### Manual Verification

* Confirmed secret names and Environment names match `docs/CI_CD_GUIDE.md` and workflow YAML (`environment: dev` / `production`).
* Confirmed workflow inventory and promote path filters match `.github/workflows/`.

### Remaining Verification (Post-Merge)

* Operator: follow `docs/SETUP.md` against a real GitHub repo + AWS account when enabling CI/CD for the first time (or audit existing setup against the checklist).

## Migration or Deployment Notes

1. No code deploy required.
2. Existing operators with working secrets/Environments need no action unless auditing against the checklist.
3. New environments should complete SETUP before relying on Promote Production or Destroy flows.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
| --- | --- | --- | --- |
| Doc drift if workflows rename Environments/secrets | Low | Medium | Update SETUP and CI_CD_GUIDE in the same PR as workflow changes |
| Operators mis-copy OIDC subjects | Medium | High | Use exact `environment:dev` / `environment:production` strings; verify with a plan-only promote |

**Rollback procedure:**

1. Delete `docs/SETUP.md` and this change document if the guide must be withdrawn.
2. No infrastructure or workflow rollback required.
