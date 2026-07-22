# Change: Document Mandate 20 EBS hourly tags and recovery points

## Summary

Updated ADR-BCP-20 gap list to mark the EBS hourly selection-tag and first
recovery-point work as done after live operator actions on 2026-07-22.

## Context

Operational PVC volumes needed the `Mandate20Backup=hourly` tag so the existing
AWS Backup plan could select them. On-demand jobs proved completed EBS recovery
points in vault `techx-prod-tf2-mandate20`. This document records the ADR
status update only; tags and jobs were applied in AWS (not Terraform).

## Before

* ADR §4.2 listed EBS tag + recovery point as open pre-drill work.

## After

* ADR §4.2 marks EBS tag + three COMPLETED recovery points as **DONE 2026-07-22**
  with volume/snapshot identifiers.

## Technical Design Decisions

* Ops-only tag/backup (CLI) rather than waiting for Terraform ownership of the
  hourly plan; TF import remains a separate optional follow-up.

## Implementation Details

1. Operator-approved `create-tags` and `start-backup-job` for three PVC volumes.
2. Jobs completed; vault lists three EBS recovery points.
3. ADR gap bullet updated with evidence identifiers.

## Files Changed

**Documentation:**

* `docs/adr/ADR-BCP-20-phoenix-resilience-and-zero-data-loss.md` — gap closed note.
* `docs/changes/2026-07-22-mandate-20-ebs-hourly-tags-rps.md` — this record.

**AWS (exception):** volume tags + backup recovery points — not Git files.
Change trail exception for AWS state: evidence in workspace
`docs/changes/2026-07-22-mandate-20-ebs-hourly-tag-and-rps.md`. Attribution:
@hungxqt.

## Dependencies and Cross-Repository Impact

* Related: workspace `docs/mandate-20/IMPLEMENTATION-DEPLOYMENT-PLAN.md` and
  `docs/changes/2026-07-22-mandate-20-ebs-hourly-tag-and-rps.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No code change |
| **Infrastructure** | Docs only in this repo; AWS tags/RPs applied out of band |
| **Deployment** | None |

## Validation

### Automated Checks

| Check | Result |
|---|---|
| Vault EBS COMPLETED RPs | 3 |
| Tagged volumes | 3 |

### Remaining Verification (Post-Merge)

* Optional Terraform import of EBS hourly plan.

## Migration or Deployment Notes

None.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| ADR overstates TF ownership | Low | Low | Text states CLI/ops evidence |

**Rollback procedure:** Revert this ADR wording if evidence is invalidated.

<!-- Change trail: @hungxqt - 2026-07-22 - ADR note for EBS hourly tags and RPs. -->
