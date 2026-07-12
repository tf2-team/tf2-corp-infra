# Change: Document Chart Soft Topology Spread Balancing

## Summary

Documented that pod topology balancing is implemented as **soft** chart-side `topologySpreadConstraints` on the spot-tolerant contract. No Terraform, NodePool, or MNG contract changes.

## Context

The application chart added soft zone/hostname spreads so multi-replica stateless pods can balance within the Karpenter pool without weakening Phase 1 hard placement. Infra docs previously listed topology entirely as a follow-up.

## Before

* Status table listed “Admission / PDB / topology” as a single follow-up row.
* App chart row mentioned hard selectors only.

## After

* Status distinguishes **chart soft topology spread** (implemented) from **admission / PDB / hard topology** (still follow-up).
* App chart behavior notes soft spreads on the default spot-tolerant contract.
* Related docs link to the chart change record and ops guide.

## Technical Design Decisions

* Docs-only update in this repository — capacity surface (multi-AZ MNG + Karpenter AZs) already exists.
* Hard placement and NodePool weights remain the source of truth for *where* pods may run; chart topology only balances *among* eligible nodes.

## Implementation Details

1. Updated `docs/workload-placement.md` implementation status and configured-behavior rows.
2. Added related-doc links to chart ops and chart change record.

## Files Changed

**Documentation:**

* `docs/workload-placement.md` — soft topology status + cross-links.
* `docs/changes/2026-07-11-pod-topology-spread-balancing.md` — this change record.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-chart/docs/changes/2026-07-11-pod-topology-spread-balancing.md`
* Chart must be synced for runtime balancing behavior; this infra change is documentation only.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change from this repo |
| **Infrastructure** | No Terraform or node contract change |
| **Deployment** | None |
| **Backward compatibility** | Fully backward-compatible (docs only) |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| N/A | Docs-only | N/A |

### Manual Verification

* Review links resolve to chart ops/change paths.

### Remaining Verification (Post-Merge)

* None for infra.

## Migration or Deployment Notes

None.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| None (docs only) | — | — | Revert markdown |

**Rollback procedure:**

Revert this documentation change.
