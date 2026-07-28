# Mandate 21 Person 1 Evidence Index — 2026-07-28

This index separates implemented configuration from live evidence. No live FIS experiment or skip-all preview was started during this change.

| Gate | Status | Evidence |
|---|---|---|
| Four-template Terraform contract | Implemented, pending apply | Wrapper `schemaVersion = 1`; internal module schema `2.0`; tests pass |
| FIS skip-all for all four templates across both AZs | PENDING | [fis-skip-all.md](fis-skip-all.md) |
| Capacity/Karpenter five-minute proof | FAIL | [capacity-karpenter.md](capacity-karpenter.md) |
| Audit controls | FAIL | [audit-gate.md](audit-gate.md) |
| Weekly Cost Explorer estimate and forecast | FAIL | [cost-forecast.md](cost-forecast.md) |
| Live drill | NOT AUTHORIZED | Requires every preceding gate to pass |

The live account still exposes the old two zone-keyed FIS templates. The current RDS primary snapshot is `us-east-1a`, with a Multi-AZ secondary in `us-east-1b`. Four-template skip-all evidence cannot be claimed until the reviewed Terraform plan is applied and separately approved previews complete for all four templates. Live execution must still select only the variant matching the fresh RDS-primary snapshot.

**Overall Mandate 21 Person 1 gate: FAIL.**

<!-- Change trail: @hungxqt - 2026-07-28 - Indexed current capacity, audit, cost, and pending FIS preview evidence without claiming gate completion. -->
