# Change: Argo CD bootstrap outputs use root app-of-apps

## Summary

Updated Terraform environment outputs so post-Argo install bootstrap commands apply `gitops/bootstrap/{env}/` (root app-of-apps) instead of applying every file under `gitops/clusters/{env}/` directly.

## Context

The chart repository now owns a durable root Application that reconciles child Application/AppProject CRs. Infra bootstrap notes still pointed operators at the old per-directory apply path.

## Before

* `argocd_bootstrap_apply_commands` suggested `kubectl apply -f .../gitops/clusters/prod/` (or dev).
* Dev output referenced incorrect app names (`techx-corp` instead of `techx-corp-dev`).

## After

* Prod/dev outputs apply `gitops/bootstrap/{prod,dev}/`.
* Wait sequence: root → secrets Application → store Application.

## Technical Design Decisions

* Docs/outputs only — no Terraform resource or module behavior change.
* Keep ownership of Application CRs in the chart repo; infra only documents the one-time seed command.

## Implementation Details

1. Updated `environments/production/outputs.tf` `argocd_bootstrap_apply_commands`.
2. Updated `environments/development/outputs.tf` similarly with correct dev app names.
3. Added this change document.

## Files Changed

* `environments/production/outputs.tf` — root bootstrap command string.
* `environments/development/outputs.tf` — root bootstrap command string.
* `docs/changes/2026-07-16-argocd-bootstrap-root-app.md` — this record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-chart/docs/changes/2026-07-16-argocd-app-of-apps-bootstrap.md`
* Requires chart repo merge of `gitops/bootstrap/**` for the documented paths to exist.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None until operators run the printed commands |
| **Infrastructure** | No cloud resource change (outputs only) |
| **Deployment** | Correct bootstrap path after Argo install |
| **Backward compatibility** | Old apply path still works but is non-preferred |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt/validate | Not run (string-only output change) | N/A |

### Manual Verification

* Reviewed output HEREDOC text for prod and dev.

### Remaining Verification (Post-Merge)

```cmd
terraform -chdir=environments/production output -raw argocd_bootstrap_apply_commands
terraform -chdir=environments/development output -raw argocd_bootstrap_apply_commands
```

## Migration or Deployment Notes

None for apply. Operators use the new output after chart bootstrap path is on the tracked branch.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operators run commands before chart merge | Low | Low | Chart must land first or apply fails on missing path |

**Rollback procedure:** Revert this commit; restore previous output strings.

<!-- Change trail: @hungxqt - 2026-07-16 - Document Argo root bootstrap output change. -->
