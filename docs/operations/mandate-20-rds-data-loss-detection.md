# Mandate 20 RDS Destructive-DDL Detection

## Purpose

This control provides an early signal for controlled or unexpected schema loss
on the production commerce RDS instance. It supports the Mandate 20 recovery
runbook; it does not select a restore point or start PITR automatically.

```text
PostgreSQL log_statement=ddl
  -> RDS PostgreSQL log export
  -> CloudWatch Logs metric filter
  -> CloudWatch alarm
  -> dedicated Mandate 20 SNS alert topic
  -> configured email subscribers
```

The dedicated topic is intentionally unencrypted because its alarm messages
contain status metadata only, not SQL payloads, credentials, or customer data.
The organization SCP prevents the production apply role from changing the KMS
policy of the existing encrypted Mandate 12 topic; this design preserves that
guardrail instead of requesting a bypass.

The filter covers `DROP TABLE` and `TRUNCATE TABLE` statements written with
consistently upper-case or lower-case SQL keywords. The existing hot-path
Grafana alerts continue to detect checkout error-rate and latency symptoms.

## Safety boundaries

* Use only a uniquely named canary table for a drill.
* Do not delete, truncate, or update application tables.
* Do not route the restored database to production workloads.
* Do not start PITR solely because this alarm fires.
* Do not disable `flagd` or expose private operational endpoints.
* Keep the restored target until the mentor has inspected the evidence.

## Deployment verification

After Terraform apply, verify the RDS parameter group, log export, filters,
alarm, and subscription before running a destructive statement:

```powershell
aws rds describe-db-parameters `
  --db-parameter-group-name techx-prod-tf2-postgresql `
  --source user `
  --region us-east-1

aws logs describe-metric-filters `
  --log-group-name /aws/rds/instance/techx-prod-tf2-postgresql/postgresql `
  --region us-east-1

aws cloudwatch describe-alarms `
  --alarm-names techx-prod-tf2-postgresql-destructive-ddl-detected `
  --region us-east-1

aws sns list-subscriptions-by-topic `
  --topic-arn <mandate20-data-loss-alert-topic-arn> `
  --region us-east-1
```

The SNS subscription must be `Confirmed`. Applying Terraform does not confirm
an email subscription on behalf of its recipient.

## Controlled canary test

Record all timestamps in UTC. Create a canary in the approved production
database connection:

```sql
CREATE TABLE m20_canary_20260725 (
    id          integer PRIMARY KEY,
    payload     text NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO m20_canary_20260725 (id, payload, created_at)
VALUES (1, 'mandate20-controlled-canary-v1', NOW());

SELECT id, payload, created_at
FROM m20_canary_20260725
ORDER BY id;
```

Save the output, row count, marker, timestamp, and stable SHA-256. Wait until
RDS `LatestRestorableTime` is later than the committed canary timestamp. Record
an approved `T_safe` after the insert and before the destructive statement.

Cause only the controlled loss:

```sql
DROP TABLE m20_canary_20260725;

SELECT to_regclass('public.m20_canary_20260725');
```

The second query must return `NULL`. Record `T_loss` immediately.

## Alert verification

Within the alarm evaluation and delivery interval, collect:

1. The RDS PostgreSQL log event containing `DROP TABLE`.
2. The `TechX/Mandate20/DestructiveDdlDetected` metric datapoint.
3. Alarm history showing transition to `ALARM`.
4. The SNS email notification and its receive time.
5. Detection latency: `T_alert_received - T_loss`.

An alarm confirms that destructive DDL was observed. It does not prove data
recovery. Continue the formal isolated PITR drill, verify the restored canary
and hash, and measure RPO/RTO as defined in ADR-BCP-20.

## Response

For an approved drill, record the alert and continue the mentor-observed
runbook. For an unexpected event:

1. Confirm the affected database, statement, actor, and time.
2. Isolate the suspected writer if corruption may continue.
3. Preserve logs and determine `T_loss` and an approved `T_safe`.
4. Restore to a new private target and verify integrity.
5. Require separate approval for selective import or production cutover.

