# Mandate 21 Infrastructure Runbook: Availability Zone Failover Drill

## 1. Objective and safety boundary

This runbook selects and validates one of four immutable AWS FIS templates for a controlled `us-east-1a` or `us-east-1b` failure. Terraform and Git remain the desired-state path. Do not run direct mutating Helm or kubectl commands against Argo CD-managed resources.

Starting a skip-all preview, live experiment, or manual stop changes AWS state and requires separate explicit approval immediately before the command. A successful Lambda/FIS API call is not sufficient evidence; every gate below must be satisfied.

## 2. Template contract

The production output `mandate21_fis_contract` uses the Person 3 wrapper schema (`schemaVersion = 1`) with nested `zones.<az>.primaryInZoneTemplateId` and `primaryOutsideZoneTemplateId` fields. The internal module retains schema `2.0` metadata for these stable variants:

| Fault AZ | RDS primary relation | Variant | RDS target/action |
|---|---|---|---|
| `us-east-1a` | Primary in `1a` | `1a-primary-in` | Included |
| `us-east-1a` | Primary outside `1a` | `1a-primary-outside` | Omitted |
| `us-east-1b` | Primary in `1b` | `1b-primary-in` | Included |
| `us-east-1b` | Primary outside `1b` | `1b-primary-outside` | Omitted |

All four templates use `empty_target_resolution_mode = "fail"`. The two `primary-outside` templates intentionally contain neither an RDS target nor a `FailoverRDS` action; this is omission by design, not an empty target that may be skipped.

## 3. Mandatory pre-drill gates

Keep the overall gate `FAIL` unless every item is proven at the same deployment revision:

1. **Cost:** normalized steady-state and conservative drill-week forecasts are each `<= $300/week`.
2. **Audit:** the three underlying audit alarms and aggregate audit-control alarm are `OK`; relevant DLQ visible counts are zero for two complete evaluation windows.
3. **Capacity:** a controlled GitOps load probe proves either surviving AZ sustains the five-minute recovery profile; NodePool limits, subnet IPs, quotas, Pending pods, and Karpenter churn are acceptable.
4. **Revision stability:** Argo CD is `Synced/Healthy` for 30 continuous minutes at the recorded revision.
5. **Template deployment:** Terraform output exposes wrapper `schemaVersion = 1`, exact runtime context, RDS identifier, and two template IDs under each AZ.
6. **Target preview:** all four templates complete `actionsMode=skip-all` with their required targets resolved; this is separate from selecting the current-valid variant for a live fault.
7. **Application durability:** Person 2 durability and idempotency evidence is approved.

## 4. Resolve RDS primary and select templates

Immediately before preview or live start, query the managed RDS instance:

```cmd
aws rds describe-db-instances --region us-east-1 --db-instance-identifier techx-prod-tf2-postgresql --query "DBInstances[0].{AvailabilityZone:AvailabilityZone,SecondaryAvailabilityZone:SecondaryAvailabilityZone,MultiAZ:MultiAZ,Status:DBInstanceStatus}" --output json
```

Reject the run if the response is missing, older than the current preflight, not `available`, not `MultiAZ=true`, or changes before experiment start. Select templates using this mapping:

| Fault AZ | Current RDS primary AZ | Selected variant |
|---|---|---|
| `us-east-1a` | `us-east-1a` | `1a-primary-in` |
| `us-east-1a` | `us-east-1b` | `1a-primary-outside` |
| `us-east-1b` | `us-east-1b` | `1b-primary-in` |
| `us-east-1b` | `us-east-1a` | `1b-primary-outside` |

Resolve the template ID only from the reviewed Terraform output. Reject arbitrary IDs or mismatches between `FaultZone`, `RdsPrimaryRelation`, `TemplateVariant`, and the fresh RDS snapshot.

```cmd
terraform output -json mandate21_fis_contract
```

## 5. Skip-all target preview

After explicit approval for the exact bounded preview set, run all four template IDs one at a time:

```cmd
aws fis start-experiment --region us-east-1 --experiment-template-id <resolved-id> --experiment-options actionsMode=skip-all
```

Record each experiment ID, terminal state, template variant, RDS snapshot time, and resolved target counts. Do not treat a preview of a stale relation as authorization to use that variant for a live fault. Assert:

- EC2 instances are running and located only in the fault AZ.
- Subnet ARNs are the intended private subnets in the fault AZ.
- Valkey resolves in the fault AZ.
- `primary-in` resolves exactly the RDS DB target and includes `FailoverRDS`.
- `primary-outside` exposes no RDS target or action.
- Any required empty target fails the preview and leaves the gate `FAIL`.

Skip-all proves target resolution and log configuration only. It does not prove action permissions, rollback, capacity recovery, or application RTO.

## 6. Live drill sequence

1. Record the Git/Argo revision, alarms, Cost Explorer window, RDS primary snapshot, capacity evidence, and selected variant.
2. Person 3 starts the approved steady load through GitOps-managed configuration.
3. Obtain explicit approval for the exact experiment template ID and blast radius.
4. Start the experiment and monitor FIS, ALB, EC2, RDS, Valkey, audit health, durability, payment idempotency, and the five-minute RTO.
5. Re-query RDS before any second-AZ drill and recompute the variant; do not reuse the previous primary snapshot.

## 7. Abort and cleanup

CloudWatch stop conditions terminate the fault when a guard alarm breaches. For an unmonitored anomaly, obtain explicit approval for the exact experiment and then run:

```cmd
aws fis stop-experiment --region us-east-1 --id <experiment-id>
```

After a terminal state, verify no experiment-created NACL association remains, stopped EC2 instances recovered or were replaced, RDS and Valkey endpoints are healthy, ALB targets are healthy, Argo CD is `Synced/Healthy`, audit alarms recover naturally, and no manual kubectl mutation occurred. Do not use `set-alarm-state`, purge a DLQ, or redrive messages until the consumer is fixed and a separate bounded action is approved.

## 8. Immutable-audit DLQ archive and drain

Historical immutable-audit DLQ messages must never be replayed or purged. The bounded tool reads only five queue URLs exported by the production Terraform stack: the immutable-audit Discord, health-check Lambda, K8s sealer, shared validation, and alert-router DLQs. It verifies that every current producer and its required alarms are healthy and that the archive bucket has Object Lock with default retention.

Generate the bounded Terraform output file and run the read-only inspection:

```cmd
cd /d techx-corp-infra\environments\production
terraform output -json > terraform-output.json
cd /d ..\..\..
python scripts\operations\archive-immutable-audit-dlqs.py --inspect --terraform-output-json environments\production\terraform-output.json
```

`--inspect` does not receive, archive, delete, purge, or replay messages. Do not approve `--execute` until the corrected alert router is deployed, the delivery-failure metric is active, and all producer-health alarms are `OK`. The overall audit gate remains `FAIL` until all monitored DLQs are empty, `AuditControlHealth` publishes `1`, and the three target alarms have returned to `OK` for their full evaluation windows.

The following execution command is intentionally pending separate, immediate approval. It archives each complete message document to the Object-Locked bucket, verifies the exact version with `HeadObject`, and only then deletes that single source message:

```cmd
cd /d techx-corp-infra
python scripts\operations\archive-immutable-audit-dlqs.py --execute --terraform-output-json environments\production\terraform-output.json
```

Stop on the first error. Do not use SQS purge, redrive, replay, or manual message deletion as a fallback. Retain the tool's safe counts plus archive key, SHA-256 digest, and Object Lock version evidence, alarm history, and producer-health evidence with the change record. Remove the locally generated `terraform-output.json` after the approved operation; it is operational evidence and must not be committed.

<!-- Change trail: @hungxqt - 2026-07-29 - Extend the approval-gated archive procedure to all five alarm-blocking DLQs. -->