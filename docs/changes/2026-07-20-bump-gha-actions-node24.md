# Change: Bump GitHub Actions to Node.js 24 runtimes

## Summary

Upgraded third-party GitHub Actions used by Terraform CI/CD (including Promote Production plan/apply) from Node.js 20 majors to Node.js 24–capable majors, pinned by full commit SHA. This clears the runner deprecation warnings that listed `actions/cache@v4`, `actions/checkout@v4`, `actions/upload-artifact@v4`, `actions/download-artifact@v4`, `aws-actions/configure-aws-credentials@v4`, and `hashicorp/setup-terraform@v3`.

## Context

GitHub deprecated Node.js 20 on Actions runners ([changelog](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/)). Production Promote runs (`Plan production` / `Apply production`) emitted warnings that those actions target Node 20 but are forced onto Node 24. Workflows still used floating `@v4` / `@v3` tags, contrary to `docs/CI_CD_GUIDE.md` SHA-pin guidance.

* Why now: remove deprecation noise and avoid future hard failures when Node 20 is removed.
* Constraint: keep OIDC assume-role inputs, plan artifact name/path handoff, and PR/issue scripts behaviorally unchanged.

## Before

| Action | Pin |
| --- | --- |
| `actions/checkout` | `@v4` |
| `actions/cache` | `@v4` (composite setup) |
| `actions/upload-artifact` | `@v4` |
| `actions/download-artifact` | `@v4` |
| `aws-actions/configure-aws-credentials` | `@v4` |
| `hashicorp/setup-terraform` | `@v3` (composite setup) |
| `actions/github-script` | `@v7` |
| `terraform-linters/setup-tflint` | `@v4` |

Promote Production calls `terraform-apply.yml`, which used the Node 20 pins above for plan and apply jobs.

## After

| Action | New pin |
| --- | --- |
| `actions/checkout` | `9c091bb…` **v7.0.0** |
| `actions/cache` | `55cc834…` **v6.1.0** |
| `actions/upload-artifact` | `043fb46…` **v7.0.1** |
| `actions/download-artifact` | `3e5f45b…` **v8.0.1** |
| `aws-actions/configure-aws-credentials` | `517a711…` **v6.2.2** |
| `hashicorp/setup-terraform` | `dfe3c3f…` **v4.0.1** |
| `actions/github-script` | `3a2844b…` **v9.0.0** |
| `terraform-linters/setup-tflint` | `6e1e064…` **v6.3.0** |

`bridgecrewio/checkov-action@v12` left as-is (container-based; not in the Node 20 warning set). Promote Dev/Production still only call the local reusable apply workflow.

## Technical Design Decisions

* **SHA pins with version comments** — Aligns with `docs/CI_CD_GUIDE.md`; avoids floating-tag drift.
* **Latest Node 24 majors** — Intentional major jumps (checkout v7, artifacts v7/v8, AWS credentials v6, setup-terraform v4) because older `@v4`/`@v3` tags still declare Node 20.
* **Artifact pair** — `upload-artifact@v7` with `download-artifact@v8` for same-workflow plan handoff; download-by-name path layout for our usage is unchanged.
* **github-script v9** — Scripts only use pre-injected `github`/`context` and `require("fs")`; they do not `require('@actions/github')` (v9 breaking path).
* **GitHub-hosted runners** — Actions require runner ≥ ~2.327.1 / Node 24; `ubuntu-latest` satisfies this.

## Implementation Details

1. Resolved release commit SHAs via GitHub API for each target tag.
2. Replaced third-party `uses:` lines in all Terraform workflows and the `setup-terraform-cached` composite action.
3. Documented Node 24 preference under Action pin maintenance in `docs/CI_CD_GUIDE.md`.
4. Added this change record.

## Files Changed

**Composite action:**

* `.github/actions/setup-terraform-cached/action.yml` — `actions/cache` v6.1.0, `hashicorp/setup-terraform` v4.0.1.

**Workflows:**

* `.github/workflows/terraform-apply.yml` — checkout, AWS credentials, upload/download artifact (used by Promote Production plan/apply).
* `.github/workflows/terraform-ci.yml` — checkout, AWS credentials, upload-artifact, github-script, setup-tflint.
* `.github/workflows/terraform-drift.yml` — checkout, AWS credentials, github-script.
* `.github/workflows/terraform-destroy-dev.yml` — checkout, AWS credentials.
* `.github/workflows/terraform-destroy-production.yml` — checkout, AWS credentials.

**Documentation:**

* `docs/CI_CD_GUIDE.md` — Node 24 note under action pin maintenance.
* `docs/changes/2026-07-20-bump-gha-actions-node24.md` — this change record.

## Dependencies and Cross-Repository Impact

* None for platform/chart application code.
* Chart `runtime-hardening.yml` still has `actions/checkout@v4` (out of scope; separate repo).
* Operators must re-run Promote Production after merge to confirm OIDC + plan artifact download warnings are gone.

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Application behavior** | No Terraform or AWS resource change |
| **Infrastructure** | No change |
| **Deployment** | GitHub Actions only; no cluster/Helm apply |
| **Performance** | Negligible |
| **Security** | Newer action dependency trees; SHA pins remain |
| **Reliability** | Avoids future Node 20 runtime removal failures |
| **Cost** | None |
| **Backward compatibility** | Workflow YAML only; plan artifact I/O path unchanged for by-name download |
| **Observability** | Removes Node 20 deprecation annotations on plan/apply jobs |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
| --- | --- |
| Pin inventory | Search for `@v4` / `@v3` third-party pins under `.github/` | ✅ Only `checkov-action@v12` remains (intentional) |
| Release SHAs | GitHub API tag peel for each action | ✅ Resolved |

### Manual Verification

* Confirm Promote Production `Plan production` / `Apply production` no longer list Node 20 deprecation for the upgraded actions (post-merge).

### Remaining Verification (Post-Merge)

1. Run **Promote Production** with `plan_only: true` (or open a PR that triggers Terraform CI) and confirm green OIDC + plan.
2. Optionally complete a real apply after environment approval when a real change is ready.
3. Confirm annotations no longer mention the listed `@v4`/`@v3` actions.

## Migration or Deployment Notes

1. Merge this change to the default branch of `techx-corp-infra`.
2. Re-run Promote Production (or Terraform CI plan matrix) to validate.
3. No Terraform apply of infrastructure is required for this workflow-only change.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
| --- | --- | --- | --- |
| Artifact major mismatch breaks plan download | Low | Medium | upload v7 + download v8 same workflow; revert SHAs if download fails |
| configure-aws-credentials v6 OIDC edge case | Low | High | Same `role-to-assume` / `aws-region` inputs; revert to prior SHA if assume-role fails |
| github-script v9 ESM break | Low | Low | Scripts do not `require('@actions/github')` |

**Rollback procedure:**

1. Revert the commit that introduced this change (or restore previous `uses:` pins in the listed workflow files).
2. Push to the default branch so subsequent Promote/CI runs pick up the prior pins.

<!-- Change trail: @hungxqt - 2026-07-20 - Bump GHA actions to Node 24 runtimes for Terraform CI/CD. -->
