# Migrate audit schedules to EventBridge Scheduler

Mandate 12 recurring audit-control jobs previously used legacy scheduled EventBridge rules. This change moves the four recurring jobs to EventBridge Scheduler in a dedicated schedule group:

- `techx-prod-tf2-mandate12-immutable-audit-health-check`
- `techx-prod-tf2-k8s-audit-sealer`
- `techx-prod-tf2-cloudtrail-validator`
- `techx-prod-tf2-k8s-manifest-validator`

Event-pattern rules for tamper detection remain as EventBridge rules because they are event routing rules, not recurring schedules.

The cadence remains unchanged:

- Health check: `rate(5 minutes)`. The audit health alarms evaluate two 5-minute periods with missing data treated as breaching, so this gives roughly 10-minute fail-closed drift detection without spamming control-plane APIs.
- K8s audit sealer: `rate(15 minutes)`. The sealer's manifest window is also 15 minutes, with a 10-minute delivery delay, so each run seals one stable window after Firehose delivery has time to finish.
- CloudTrail validator: `rate(1 hour)`. The health check accepts validation reports up to 180 minutes old, so hourly validation gives three report opportunities before staleness is treated as control drift.
- K8s manifest validator: `rate(1 hour)`. The K8s manifest validation lookback is six hours and the same 180-minute health freshness threshold applies, so hourly validation is frequent enough for evidence freshness without re-validating the manifest chain every few minutes.

All schedules use `Etc/UTC`, `flexible_time_window = OFF`, bounded retries, and DLQs for failed target delivery. The health-check Lambda now validates Scheduler schedules with `scheduler:GetSchedule` while still validating event-pattern tamper rules through EventBridge.

Change trail: @hungxqt - 2026-07-30 - Replaced recurring audit scheduled rules with EventBridge Scheduler and documented cadence rationale.
