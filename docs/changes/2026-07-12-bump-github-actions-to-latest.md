# Change: Bump GitHub Actions in infra CI/CD to latest

## Summary

Refreshed every third-party GitHub Action pin under `techx-corp-infra/.github/workflows` to the latest published release commit SHA (with accurate version comments). Local reusable workflow calls (Promote Dev/Prod → `terraform-apply.yml`) are unchanged. Checkov action commit was already latest; only the version comment was clarified.

## Context

Action pins had drifted (checkout v4, setup-terraform v3, AWS credentials v4, artifacts v4, github-script v7, setup-tflint v4, codeql-action v3). Operator requested updating all infra CI/CD actions to latest while keeping the repo’s full-SHA pin convention.

## Before

| Action | Pinned (approx) |
| --- | --- |
| `actions/checkout` | v4 SHA |
| `hashicorp/setup-terraform` | v3 SHA |
| `aws-actions/configure-aws-credentials` | v4 SHA |
| `actions/upload-artifact` | v4 SHA |
| `actions/download-artifact` | v4 SHA |
| `actions/github-script` | v7 SHA |
| `terraform-linters/setup-tflint` | v4 SHA |
| `bridgecrewio/checkov-action` | v12 SHA (`7b972723…`) |
| `github/codeql-action/upload-sarif` | v3 SHA |

## After

| Action | New pin |
| --- | --- |
| `actions/checkout` | `9c091bb…` **v7.0.0** |
| `hashicorp/setup-terraform` | `dfe3c3f…` **v4.0.1** |
| `aws-actions/configure-aws-credentials` | `517a711…` **v6.2.2** |
| `actions/upload-artifact` | `043fb46…` **v7.0.1** |
| `actions/download-artifact` | `3e5f45b…` **v8.0.1** |
| `actions/github-script` | `3a2844b…` **v9.0.0** |
| `terraform-linters/setup-tflint` | `6e1e064…` **v6.3.0** |
| `bridgecrewio/checkov-action` | `7b972723…` **v12.3114.0** (same commit; comment only) |
| `github/codeql-action/upload-sarif` | `99df26d…` **v4.37.0** |

Workflows updated: `terraform-ci.yml`, `terraform-apply.yml`, `terraform-drift.yml`, `terraform-destroy-dev.yml`, `terraform-destroy-production.yml`. Promote workflows only call the local reusable apply workflow (no third-party pins).

## Technical Design Decisions

* **Latest majors allowed:** User asked for latest; this intentionally jumps majors (contrary to routine “same major only” guidance). Documented as intentional refresh.
* **Keep SHA pins:** Still no floating `@vN` tags.
* **Version comments use concrete tags** (`# v7.0.0`) where resolved, not only major.
* **Artifact pair:** upload v7 + download v8 kept in lockstep for plan artifact handoff.
* **Checkov:** Latest tag `v12.3114.0` already pointed at existing pin; no code change beyond comment.
* **Node 24:** Several actions (checkout, setup-terraform, configure-aws-credentials) require modern GitHub-hosted runners (Node 24 / runner ≥ ~2.327.1). Acceptable for `ubuntu-latest`.

## Implementation Details

1. Resolved each action’s latest release tag and peeled commit SHA via GitHub API.
2. Bulk-replaced `uses:` lines across workflow YAML files.
3. Updated `docs/CI_CD_GUIDE.md` action pin maintenance notes for intentional major bumps.
4. Added this change record.

## Files Changed

**Workflows:**

* `.github/workflows/terraform-ci.yml`
* `.github/workflows/terraform-apply.yml`
* `.github/workflows/terraform-drift.yml`
* `.github/workflows/terraform-destroy-dev.yml`
* `.github/workflows/terraform-destroy-production.yml`

**Docs:**

* `docs/CI_CD_GUIDE.md` — pin maintenance guidance
* `docs/changes/2026-07-12-bump-github-actions-to-latest.md` — this record

## Dependencies and Cross-Repository Impact

* **Platform / chart:** None.
* **GitHub-hosted runners:** Must support Node 24 actions (current `ubuntu-latest` does).
* **Operators:** Re-run Terraform CI / Promote Dev plan path after merge to validate OIDC + artifact download.

## Impact Analysis

| Dimension | Impact |
| --- | --- |
| **Application behavior** | None |
| **Infrastructure** | None directly; CI tooling only |
| **Deployment** | Promote apply still uses same reusable workflow; artifact format remains default zipped |
| **Security** | Newer action code; still SHA-pinned |
| **Reliability** | Major bumps may change edge-case defaults (e.g. download digest mismatch → error); monitor first CI runs |
| **Cost** | None |
| **Backward compatibility** | Floating consumers of old major tags N/A (repo already SHA-pinned) |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
| --- | --- | --- |
| Pin inventory | `rg "uses:" .github/workflows` | All third-party pins updated |
| actionlint | `actionlint` (if installed) | Run if available |

### Manual Verification

* Open PR → Terraform CI green (fmt/validate/tflint/checkov/plan).
* Promote Dev plan+apply (or plan-only path) downloads `tfplan` artifact successfully.
* Checkov SARIF upload remains best-effort (`continue-on-error`).

### Remaining Verification (Post-Merge)

1. First PR after merge exercises all CI jobs.
2. One Promote Production `plan_only=true` run to exercise apply reusable workflow plan path.
3. If download-artifact fails on digest, set `digest-mismatch` only after confirming root cause.

## Migration or Deployment Notes

None for AWS/bootstrap. Merge and let CI run.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
| --- | --- | --- | --- |
| Node 24 unsupported on custom runners | Low (hosted runners OK) | High | Use GitHub-hosted or upgrade runners |
| download-artifact digest default error | Low | Medium | Revert download pin or set `digest-mismatch` |
| OIDC/credentials input strictness (v5+) | Low | Medium | Existing boolean inputs already valid true/false |
| Unexpected major behavior | Medium | Medium | Revert workflow files to previous SHAs |

**Rollback procedure:** Revert this commit (or restore previous `uses:` SHAs) and re-run CI.
