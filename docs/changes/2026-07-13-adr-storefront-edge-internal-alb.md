# Change: ADR — internal ALB as CloudFront VPC origin

## Summary

Added an architecture decision record explaining why the storefront still uses an **internal ALB** behind CloudFront VPC origin, what roles CloudFront vs ALB own, and which alternatives were rejected (no LB, public ALB + lock-down, NLB-only, etc.).

## Context

After moving path blocking to CloudFront and the ALB to `scheme: internal`, operators and reviewers asked whether the ALB hop is still necessary. The decision needed a durable, reviewable document next to the CloudFront runbook.

## Before

* Edge design lived in `docs/cloudfront.md` and change records, but no ADR answered “do we need the internal ALB?”
* Chart `values-public-alb.yaml` described posture without linking rationale.

## After

* New ADR: `docs/adr/storefront-edge-internal-alb.md` (status Accepted, 2026-07-13).
* `docs/cloudfront.md` Related section links the ADR.
* Chart overlay comments point at the ADR path for cross-repo readers.

## Technical Design Decisions

* ADR lives under **infra** `docs/adr/` because the open question is primarily edge/origin architecture; chart keeps a one-line pointer.
* English, table-heavy format consistent with recent infra ops docs (not the older Vietnamese SEC-05 ADR style), for cross-repo agents and operators.

## Implementation Details

1. Wrote ADR covering mandatory VPC origin types, role split, alternatives A–F, consequences, non-goals, implementation map, review triggers.
2. Linked from `docs/cloudfront.md`.
3. Linked from `techx-corp-chart/values-public-alb.yaml` header comments (cross-repo path).

## Files Changed

**Documentation:**

* `docs/adr/storefront-edge-internal-alb.md` — ADR body.
* `docs/cloudfront.md` — Related link.
* `docs/changes/2026-07-13-adr-storefront-edge-internal-alb.md` — This change record.

**Cross-repo (chart, separate commit):**

* `values-public-alb.yaml` — pointer to ADR (documented in chart change record if committed with chart edits).

## Dependencies and Cross-Repository Impact

* Chart comment link only; no runtime dependency.
* Related implementation changes: `2026-07-13-internal-alb-cloudfront-vpc-origin.md` (infra), chart `2026-07-13-internal-alb-no-path-blocks.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None (documentation only) |
| **Infrastructure** | None |
| **Deployment** | None |
| **Backward compatibility** | Fully compatible |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A (docs only) | — | N/A |

### Manual Verification

* ADR path resolves from `docs/cloudfront.md` relative link.
* Decision tables match implemented module + chart defaults.

### Remaining Verification (Post-Merge)

* None.

## Migration or Deployment Notes

None.

## Risks and Rollback

None for documentation-only addition.

**Rollback procedure:** Delete the ADR file and reverse Related/comment links.
