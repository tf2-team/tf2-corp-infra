# Audit Gate Evidence — 2026-07-28

## Current alarms

| Alarm | Observed condition | Status |
|---|---|---|
| `techx-prod-tf2-audit-alert-ready-dlq-visible-messages` | `26` visible messages | ALARM |
| `techx-prod-tf2-mandate12-immutable-audit-health-check-errors` | Historical datapoint `1` | ALARM |
| `techx-prod-tf2-mandate12-immutable-audit-health-lambda-dlq-visible` | `1` visible message | ALARM |
| `techx-prod-tf2-mandate12-immutable-audit-control-health` | Health metric `0` | ALARM (aggregate validation) |

The three underlying alarms are the alert-ready router DLQ, health-check Lambda Errors, and health-check Lambda DLQ. The aggregate control-health alarm must recover naturally after the underlying conditions are fixed.

## Implemented remediation

The health Lambda now publishes `AuditControlHealth=0` and returns structured `FAIL` for detected control drift instead of raising and placing an expected drift event into its own DLQ. Publication/execution failures still raise and remain visible through Lambda Errors and the DLQ. Five isolated unit tests pass.

The alert-ready router event mapping is enabled, but this repository intentionally contains a placeholder router package. The `26` existing messages therefore remain an unresolved consumer/deployment dependency. This change does not implement the production router, inspect message bodies, purge queues, redrive messages, or set alarm state.

## Gate result

**Audit gate: FAIL.** After deployment, fix the real router consumer, obtain separate approval for bounded redrive/cleanup, and require the three underlying alarms plus aggregate alarm to remain `OK` for two complete evaluation windows.

<!-- Change trail: @hungxqt - 2026-07-28 - Documented the health-Lambda fix and unresolved router DLQ without clearing alarms artificially. -->
