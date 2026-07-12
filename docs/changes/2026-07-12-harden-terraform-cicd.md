# Change: Harden Terraform CI/CD Promotion and Safety Controls

## Summary

GitHub Actions Terraform pipelines were hardened: production promotion is manual-only, plan publication is limited to safe structural summaries, production destroy uses plan-then-approve, drift issues have a single-issue lifecycle, Checkov SARIF is published with best-effort code scanning, TFLint uses a pinned AWS ruleset, and third-party Actions are pinned to immutable SHAs.

## Context

Evaluation of the infra CI/CD flow found production auto-apply on `main` push (including shared `modules/**`), raw plan text in PR comments and drift issues, weak destroy confirmation, drift issue spam, unpinned Actions, and incomplete Checkov/TFLint packaging. Operators need a sequential promote model and reduced leakage of plan contents without changing AWS IAM resources in this change.

## Before

* Promote Production triggered on `push` to `main` for production paths, modules, and workflows (could race dev).
* PR/drift published full `terraform show -no-color` plan text (attribute-level data risk).
* Binary plans retained up to 14–30 days on CI/apply paths.
* Destroy workflows ran Environment-gated `destroy -auto-approve` without a typed confirmation job or production destroy plan review.
* Drift opened a new issue on every detection without closing when clean.
* Checkov had no SARIF artifact/code-scanning upload.
* TFLint ran without a pinned `.tflint.hcl` / AWS ruleset init.
* Actions used floating major tags (`@v4`, `@v3`, etc.).
* `docs/CI_CD_GUIDE.md` described repository variables, manual-only production (while YAML auto-pushed), and incomplete workflow inventory; typo `enviroments/dev`.

## After

* Promote Production is `workflow_dispatch` only (with `plan_only`); Promote Dev remains path-filtered auto-apply on `main`.
* Safe summaries via `scripts/render-terraform-plan-summary.sh` (counts + ≤200 addresses only).
* Apply/destroy binary plans: 3-day retention; CI/drift: safe summary only, 7-day retention.
* Destroy dev: confirm `destroy-dev` in unprotected job, then Environment destroy.
* Destroy production: confirm `destroy-production` → plan destroy → Environment apply of immutable plan (skip apply if no changes).
* Drift: one open issue per env title; body replace while drifting; resolve comment + close when clean; errors do not mutate issues.
* Checkov SARIF artifact + best-effort code scanning; Checkov remains a hard gate.
* `.tflint.hcl` with Terraform recommended + AWS ruleset v0.48.0; `tflint --init` in CI.
* Third-party Actions pinned to full SHAs with `# vN` comments.
* Concurrency groups `terraform-state-dev` and `terraform-state-production` shared across promote, destroy, and drift.
* Guide rewritten to match implemented behavior.

## Technical Design Decisions

* **Manual production promote** over auto-push: enforces soak-in-dev; avoids dual env apply on module merges.
* **Safe summaries only** on public surfaces: binary plans remain necessary for immutable apply but are short-lived and apply-path only.
* **Unprotected confirm job** before Environment: GitHub Environment approval is requested before a protected job starts; confirm must not sit behind approval.
* **Production destroy plan-then-apply** vs immediate destroy: matches promote immutability and allows “no changes” short-circuit.
* **Keep repository secrets** (not migrate to vars): zero ops migration; guide corrected to say secrets.
* **SARIF code-scanning continue-on-error**: Advanced Security availability unknown; artifact + gate still mandatory.
* **Rejected for this change:** Infracost, post-apply smoke tests, secrets→vars migration, Checkov skip reduction, edits under `environments/production/**`.

## Implementation Details

1. Added `scripts/render-terraform-plan-summary.sh` and fixture tests under `scripts/tests/render-terraform-plan-summary/`.
2. Updated reusable `terraform-apply.yml` to render safe summaries to `$GITHUB_STEP_SUMMARY`, stage flat plan artifacts (3-day), pin Actions; removed full plan text publication.
3. Removed push trigger from Promote Production; added workflow concurrency on promote workflows.
4. Reworked destroy-dev and destroy-production with confirmation gates; production destroy uses plan role then apply role.
5. Reworked drift detection issue lifecycle with paginated search, label ensure, safe summary body.
6. Updated Terraform CI: sticky PR comments per env, no binary plan upload, Checkov SARIF, TFLint init, Action pins, `actions: read`.
7. Added `.tflint.hcl` (AWS plugin 0.48.0).
8. Rewrote `docs/CI_CD_GUIDE.md` and this change record.

## Files Changed

**Scripts:**
* `scripts/render-terraform-plan-summary.sh` — Safe plan Markdown renderer.
* `scripts/tests/render-terraform-plan-summary/run-tests.sh` — Fixture tests.
* `scripts/tests/render-terraform-plan-summary/fixtures/*.json` — Plan JSON fixtures.

**Workflows:**
* `.github/workflows/terraform-apply.yml` — Safe summary, artifacts, pins.
* `.github/workflows/terraform-promote-dev.yml` — State concurrency group.
* `.github/workflows/terraform-promote-production.yml` — Manual only + concurrency.
* `.github/workflows/terraform-destroy-dev.yml` — Confirm gate + concurrency.
* `.github/workflows/terraform-destroy-production.yml` — Confirm → plan → apply.
* `.github/workflows/terraform-drift.yml` — Safe summary + issue lifecycle + concurrency.
* `.github/workflows/terraform-ci.yml` — Sticky comments, SARIF, TFLint init, pins.

**Lint / config:**
* `.tflint.hcl` — Terraform recommended + AWS 0.48.0.

**Documentation:**
* `docs/CI_CD_GUIDE.md` — Full rewrite aligned to workflows.
* `docs/changes/2026-07-12-harden-terraform-cicd.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Platform and chart CI/CD are unchanged. Operator-managed Terraform plan/apply IAM roles and GitHub Environment reviewer settings remain required as documented; this change does not modify AWS resources.

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Application behavior** | No application runtime change |
| **Infrastructure** | No Terraform resource definitions changed in this change set |
| **Deployment** | Production infra apply is manual dispatch only; destroy production requires confirm + plan approval |
| **Performance** | Slight CI time for TFLint plugin init and SARIF upload |
| **Security** | Reduced plan data exposure; Action SHA pins; stronger destroy gates |
| **Reliability** | Shared state concurrency reduces interleaving of plan/apply/drift |
| **Cost** | Negligible (Actions minutes) |
| **Backward compatibility** | Operators who relied on auto prod promote must use workflow_dispatch |
| **Observability** | Checkov SARIF artifact; safer drift issue lifecycle |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
| --- | --- | --- |
| Renderer fixtures | `bash scripts/tests/render-terraform-plan-summary/run-tests.sh` | ✅ Pass |
| TFLint | `tflint --init && tflint --recursive --minimum-failure-severity=error` | ✅ Pass (9 existing warnings, zero errors) |
| actionlint | `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7` | ✅ Pass |
| SHA pins | Inspect workflow `uses:` for 40-char SHAs | ✅ Pass |
| Terraform validate | `init -backend=false` + `validate` for bootstrap, development, production | ✅ Pass |
| Terraform fmt | `terraform fmt -check -recursive` | ✅ Pass |

### Manual Verification

* Confirmed renderer never emits fixture secret attribute markers.
* Confirmed Promote Production YAML has no `push:` trigger.
* Confirmed destroy workflows require exact confirmation strings in unprotected jobs.

### Remaining Verification (Post-Merge)

* Operator: run Promote Production with `plan_only=true` in the real repo.
* Operator: verify wrong destroy confirm fails before Environment approval.
* Operator: verify drift issue create/update/close once against live GitHub API.
* Ensure GitHub Environment `production` has required reviewers configured.

## Migration or Deployment Notes

1. No new secret names; existing repository secrets remain valid.
2. Configure/confirm GitHub Environments `dev` and `production` (required reviewers on production).
3. After merge, production changes require **Actions → Promote Production**.
4. Destroy phrases: `destroy-dev` / `destroy-production` (exact).
5. When updating Actions later, replace SHAs deliberately (see CI_CD_GUIDE action-pin section).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
| --- | --- | --- | --- |
| Operators miss manual prod promote | Medium | Medium | Guide + change doc; dispatch remains one click |
| TFLint AWS 0.48.0 new errors | Low–Medium | Medium | Fix errors; do not suppress |
| Code scanning upload fails | Medium | Low | continue-on-error; SARIF artifact retained |
| Binary plan still sensitive if artifact leaked | Low | High | 3-day retention; Environment-gated apply only |

**Rollback procedure:**

1. Revert the commit(s) that introduced these workflow/doc/script changes on `main`.
2. No Terraform state or AWS resource rollback is required for this change alone.
