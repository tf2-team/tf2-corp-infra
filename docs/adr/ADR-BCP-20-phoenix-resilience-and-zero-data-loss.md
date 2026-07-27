# ADR-BCP-20: Data Backup, Recovery, and Proven PITR

* **Status:** Accepted - infrastructure gate complete; formal DynamoDB and RDS PITR drills PASS; mentor sign-off pending
* **Decision date:** 2026-07-21
* **Last reviewed:** 2026-07-27
* **Author:** CDO Data and DevOps Task Force (`tientp`)
* **Scope:** Data and reconstructable cluster state for the production Browse -> Cart -> Checkout path
* **Out of scope:** AZ/Region failover and failover-under-load testing

---

## 1. Context

Backups are not considered successful until the team restores data into an
isolated target, validates integrity, and measures recovery time. Directive 20
therefore measures:

* **RPO:** the maximum acceptable time between the recovered point and the loss.
* **RTO:** time from restore initiation until the restored data is usable and
  its integrity check passes.

The drill must never overwrite the production store. Cost is controlled through
bounded retention and temporary restore targets, not through an always-on DR
standby.

---

## 2. Production Data Inventory

| Layer | Production resource | Purpose / path | System of record | Backup or recovery mechanism | Scope decision |
| :--- | :--- | :--- | :--- | :--- | :--- |
| RDS PostgreSQL | `techx-prod-tf2-postgresql` | Browse, orders, accounting | Yes | Automated backup, continuous transaction logs, AWS Backup snapshot | In scope |
| DynamoDB | `techx-prod-tf2-checkout-outbox` | Durable checkout delivery until RDS persistence ACK | Yes, while delivery is incomplete | PITR and daily AWS Backup recovery point | In scope |
| ElastiCache Valkey | `techx-prod-tf2-cart` | Customer cart | Yes for active cart state | Daily automated snapshot | In scope |
| Amazon MSK | `techx-prod-tf2-msk` | Event transport | No | Replay from the DynamoDB outbox; no broker snapshot commitment | In scope as transport |
| Mem0 RDS | `techx-prod-tf2-mem0-postgres` | Shopping-copilot memory | Yes when the workload is enabled | Automated backup and AWS Backup snapshot | Currently outside the money path; still protected |
| EKS EBS PVCs | Grafana, Prometheus, OpenSearch | Operational telemetry | No customer transaction record | Encrypted EBS volumes selected for hourly AWS Backup by tag | Outside money path; operational recovery scope |
| Orphan EBS PVCs | In-cluster Kafka, PostgreSQL, Valkey PVCs | Replaced production stores | No longer used | Final snapshot before controlled cleanup | Migration residue; must be retired |
| GitOps / IaC | `tf2-corp-infra`, `tf2-corp-chart`, `tf2-corp-platform` | Cluster and application reconstruction | Configuration record | Git history, reviewed production overlays, Terraform remote state | In scope |
| Secret references | Helm values, ESO resources, ASM names/ARNs | Reconnect restored stores without committing secret values | Reference metadata only | Git stores references; secret values remain out of band in ASM | In scope |

Production overlays disable in-cluster Kafka, PostgreSQL, and Valkey. Their old
PVCs are not mounted by production pods and are not part of the current money
path. They must not be deleted until a final snapshot and migration verification
are recorded.

### 2.1 MSK Delivery Contract

MSK is a transport layer, not the final record of an order:

```text
DynamoDB pending
  -> publish orders to MSK
  -> DynamoDB published (item retained)
  -> accounting commits the order to RDS
  -> accounting publishes orders-persisted
  -> checkout deletes the DynamoDB item
```

Accounting uses manual Kafka offset commits. A failed RDS write is retried
without deleting the DynamoDB event. A stale-event reconciler handles the two
ambiguous cases after the configured timeout:

* Order exists in RDS: replay `orders-persisted`.
* Order is absent from RDS: conditionally change `published` back to `pending`
  so checkout republishes it.

This contract is implemented in the current workspace but is not a production
control until the accounting IRSA, `orders-persisted` topic, accounting image,
and checkout image have all been deployed and smoke-tested.

---

## 3. RPO, RTO, Cadence, and Retention

| Layer | Backup / recovery cadence | Retention | RPO target | RTO target | Isolated restore target |
| :--- | :--- | :--- | :--- | :--- | :--- |
| RDS PostgreSQL | Continuous transaction logs plus daily automated backup | 7 days; AWS Backup recovery points 14 days | <= 5 minutes | <= 30 minutes | New private RDS instance with `-drill-<timestamp>` suffix |
| DynamoDB outbox | Continuous PITR plus daily AWS Backup | PITR 35 days; scheduled recovery point 14 days | <= 10 minutes | <= 30 minutes | New table `m20-drill-outbox-<timestamp>` |
| Valkey cart | Daily snapshot window `18:00-19:00` UTC | 7 days | <= 24 hours | <= 20 minutes | New isolated replication group |
| Mem0 RDS | Continuous transaction logs plus daily automated backup | 14 days | <= 5 minutes | <= 30 minutes | New private RDS instance |
| Cluster manifests and IaC | Commit on every approved production change | Git history per repository policy | <= 1 hour | <= 60 minutes | Clean workspace and isolated reconstruction environment |
| Active operational EBS PVCs | Hourly AWS Backup selection by `Mandate20Backup=hourly` | 7 days | <= 1 hour | <= 60 minutes | New encrypted EBS volume / isolated PVC |

DynamoDB documents `LatestRestorableDateTime` as typically about five minutes
behind current time. The TF therefore commits to a 10-minute RPO rather than
claiming a one-minute recovery point that PITR cannot demonstrate reliably.
The 30-minute RTO includes full table and GSI reconstruction plus the integrity
query; it is based on the measured 2026-07-27 test restore, which required just
over 15 minutes before the isolated table became `ACTIVE`.

The hourly EBS plan selects only approved volumes carrying
`Mandate20Backup=hourly`. Prometheus and OpenSearch have completed hourly
recovery points. On 2026-07-27 the active Grafana claim was found to reference
the newer encrypted volume `vol-078bfcef3b62ce52d`, while the previously
protected `vol-0807f3ccbbfbf3bec` had become detached. The active volume was
tagged without restarting Grafana and an on-demand preflight recovery point
completed. A completed scheduled hourly recovery point for that exact volume
remains an infrastructure-gate evidence item. Production keeps the existing
`gp3-encrypted` StorageClass unchanged and creates
`gp3-encrypted-m20` for newly provisioned volumes. This avoids mutating
immutable StorageClass/PVC fields. Existing PVCs must not be recreated solely
to adopt the new StorageClass.

---

## 4. Implemented Controls and Known Gaps

### 4.1 Verified Live on 2026-07-27

* Main RDS is available, encrypted with a customer-managed KMS key, deletion
  protected, and has seven days of automated backup retention.
* Mem0 RDS is available, encrypted, deletion protected, and has fourteen days
  of automated backup retention.
* DynamoDB PITR is enabled with a 35-day recovery window and customer-managed
  KMS encryption.
* Valkey has at-rest and in-transit encryption, a seven-day snapshot retention
  setting, and the `18:00-19:00` UTC snapshot window.
* Manual Valkey preflight snapshot `m20-preflight-valkey-20260727-1004` was
  completed from primary cache cluster `techx-prod-tf2-cart-001` using the
  commerce KMS key. It proves snapshot creation but does not replace evidence of
  the first completed automated snapshot.
* AWS Backup vault `techx-prod-tf2-mandate20` is locked with minimum seven-day
  and maximum 35-day retention and contains 361 recovery points at the time of
  verification.
* Completed AWS Backup recovery points exist for the main RDS, Mem0 RDS, and
  DynamoDB outbox.
* On-demand backup job `911ae849-a6c3-4b4c-9e64-416b331bf769` for active
  Grafana volume `vol-078bfcef3b62ce52d` completed from
  `2026-07-27T10:06:19+07:00` to `10:07:21+07:00`, producing encrypted recovery
  point `snap-0b9eb5165ae7f037b` in the locked Mandate 20 vault.
* Managed policy `techx-prod-tf2-deny-destructive-backup` is attached to
  `TF2-TEAM` and denies destructive RDS, DynamoDB, ElastiCache, EBS snapshot,
  and AWS Backup actions.
* An IAM simulation for principal `tuan` records `explicitDeny` for destructive
  RDS, DynamoDB, ElastiCache, EBS, and AWS Backup actions while RDS, DynamoDB,
  and AWS Backup restore actions remain `allowed`. See the
  [policy simulation evidence](../evidence/mandate-20/2026-07-27/console/iam-policy-simulation-explicit-deny-restore-allowed.png).
* Bootstrap exclusive attachment ownership was applied and a post-apply plan
  returned no changes. `GitHubTerraformProdApplyRole` now retains only
  `PowerUserAccess` as a managed policy plus its scoped Terraform IAM/state
  inline policies. The Mandate 20 deny policy is attached only to `TF2-TEAM`.
* Terraform state bucket versioning, SSE-KMS, public-access blocking and native
  lockfile use are enabled. The operator deny covers deletion of historical
  versions of the exact production state object.
* Account-level EBS encryption by default remains enabled in `us-east-1`.
* Production Secrets Manager recovery window is seven days and the backup KMS
  key has annual rotation enabled.

### 4.2 Cadence Evidence and Post-Drill Cleanup

* **VERIFIED 2026-07-27:** Valkey automatic snapshots are `available` for each
  daily window from 2026-07-20 through 2026-07-26. The replication group
  remains encrypted at rest and in transit with seven-day retention and the
  `18:00-19:00` UTC snapshot window. Manual preflight snapshot
  `m20-preflight-valkey-20260727-1004` is also `available`.
* **VERIFIED 2026-07-27:** approved active EBS volumes for Prometheus, Grafana,
  and OpenSearch carry the hourly selection tag and have recurring
  `COMPLETED` recovery points in vault `techx-prod-tf2-mandate20`. The current
  Grafana volume `vol-078bfcef3b62ce52d` has both the on-demand preflight
  recovery point and scheduled hourly recovery points, including
  `snap-020f484d9fae834b9` at 11:00 ICT and
  `snap-0d2210218fb99a150` at 12:00 ICT.
* Orphan Kafka, PostgreSQL, and Valkey PVC volumes are no longer on the
  production money path. Their final-snapshot and removal work remains a
  separate approved hygiene change: verify the managed-store migration, take
  final snapshots, then remove the orphan PVCs through GitOps. This cleanup is
  not a prerequisite for the completed isolated PITR drills and must not be
  performed ad hoc.

The `orders-persisted` application delivery contract remains relevant to
general checkout reliability but is not an infrastructure blocker for the
isolated DynamoDB drill. The drill marker uses `status=drill-hold`; the checkout
worker queries only `status=pending`, so the marker is not published.

---

## 5. Backup Deletion Authority

Day-to-day operators and attached automation identities are explicitly denied
the ability to delete protected recovery points or disable DynamoDB PITR.

| Identity class | Read / restore | Delete backup | Change retention / vault lock |
| :--- | :---: | :---: | :---: |
| `TF2-TEAM` day-to-day operators | Allowed by operational role | Denied | Denied where covered by policy |
| Normal application IRSA roles | Only required application data actions | Not granted | Not granted |
| Terraform production apply role | Approved infrastructure workflow only | Workflow-controlled; vault lock still enforces retained recovery points | Approved reviewed bootstrap/production workflow |
| Account root / approved break-glass administrator | Emergency only | Allowed only under recorded approval | Allowed only under recorded approval |

The normal operator group cannot delete backups. Infrastructure changes use
`GitHubTerraformProdApplyRole` through the protected production workflow; the
role is not assigned to human day-to-day operation. Account root remains the
emergency authority while a named break-glass role, approvers, activation
evidence, and post-use review must be recorded before ADR sign-off. Backup
retention is bounded; recovery points are not retained indefinitely.

---

## 6. Incident Recovery Procedure

1. Stop or isolate corrupted write traffic without disabling flagd or exposing
   private operational endpoints.
2. Use application logs and the audit trail to determine `T_loss`.
3. Select `T_safe` before the destructive write and verify that the provider's
   latest restorable time includes it.
4. Restore to a newly named, private, isolated resource. Never restore over the
   production source.
5. Validate schema, marker/hash, row or item counts, and relevant business
   invariants before any cutover decision.
6. Record actual RPO as `T_loss - T_safe` and actual RTO as restore initiation
   until the integrity query passes.
7. A real incident cutover requires a separate approved change to update ASM
   endpoint references and reconcile ESO/application pods.
8. Retain the corrupted source for forensics until incident approval permits
   cleanup.

### 6.1 Destructive-DDL Detection

The commerce RDS parameter group records DDL statements in the existing
encrypted PostgreSQL CloudWatch log export. CloudWatch metric filters emit
`TechX/Mandate20/DestructiveDdlDetected` for logged `DROP TABLE` and
`TRUNCATE TABLE` statements. A one-minute alarm notifies a dedicated Mandate 20
SNS topic and its confirmed email subscribers. The topic contains alarm status
metadata only and is intentionally unencrypted: the organization SCP prevents
the production apply role from changing the KMS policy of the existing
encrypted Mandate 12 topic. This preserves the SCP boundary rather than
requesting a bypass for an alert that contains no SQL payload or customer data.

This is an early-warning control, not a recovery trigger. An alarm does not
prove data loss and must never automatically select `T_safe`, start PITR,
change a production endpoint, or import restored data. The canary test and
evidence procedure are documented in
`docs/operations/mandate-20-rds-data-loss-detection.md`.

---

## 7. Formal Restore Drill Procedure

The primary drill uses DynamoDB PITR because it creates an isolated target
without changing production application routing. A supplemental RDS PITR drill
uses the same controlled-canary and isolated-target boundaries. The recorded
2026-07-27 runs and measurements are in Sections 8.1 and 8.2.

### 7.1 Infrastructure Gate

The drill starts only after:

* Terraform plan/apply and Argo CD sync are healthy.
* Required backup jobs have completed and the team has recorded current
  earliest/latest restorable timestamps.
* The active Grafana volume has a completed hourly recovery point and the
  Valkey snapshot evidence described in Section 4.2 is complete.
* Source inspection confirms the checkout worker queries
  `status-created-index` only for `status=pending`, keeping the
  `status=drill-hold` marker outside normal publishing.
* No unrelated production incident or deployment is active.

### 7.2 Controlled Loss and Restore

1. Insert a unique marker with `status=drill-hold` so the checkout worker cannot
   publish it. Record the payload hash and insert time.
2. Select `T_safe` after insertion while the marker is still present. Wait
   until DynamoDB `LatestRestorableDateTime` includes that exact `T_safe`, then
   re-read and verify the marker before deletion. This ordering makes the
   selected point provider-confirmed. Derive `T_safe` and `T_loss` from the
   DynamoDB endpoint's HTTP `Date` header and abort preflight when workstation
   clock skew exceeds 30 seconds.
3. Delete only the marker and prove it is absent from the production table.
4. Record `T_loss` and `T_restore_start`.
5. Restore the table to `T_safe` as `m20-drill-outbox-<timestamp>`.
6. Poll until the isolated table is `ACTIVE`.
7. Read the marker from the isolated table and compare its full payload hash.
8. Record `T_integrity_confirmed`, calculate actual RPO/RTO, and declare PASS
   only when RPO <= 10 minutes and RTO <= 30 minutes.
9. Keep the target for mentor inspection, then delete it only after evidence and
   sign-off are complete.

Required evidence includes commands and timestamps for marker creation,
controlled deletion, PITR request, target readiness, integrity query, RPO/RTO
calculation, production health, CloudTrail event, and cleanup.

---

## 8. Evidence Status

### 8.1 Formal DynamoDB controlled-loss PITR drill — PASS

The formal `-Execute` run completed on 2026-07-27 against
`techx-prod-tf2-checkout-outbox`. It deleted only the unique drill marker from
the source table and restored the marker into the isolated table
`m20-drill-outbox-20260727115433`; it did not overwrite or cut over production.

| Measure | Target | Actual | Result |
| :--- | :--- | :--- | :--- |
| RPO | `<= 10 minutes` | `337 seconds` (`5m 37s`) | PASS |
| RTO | `<= 30 minutes` | `16.77 minutes` | PASS |
| Restored payload integrity | Exact SHA-256 match | Expected, declared, and computed hash `92b6a3a27db9b8bf0df56a2899b213e38f1a6af5fbf969d6988faf2c23bd98d7` | PASS |
| Controlled-loss proof | Marker absent from source after delete and restore | `SourceMarkerAbsent=true` | PASS |
| Production isolation | Source never overwritten | `ProductionOverwritten=false` | PASS |
| Storefront availability | Healthy before and after | HTTP `200` before and HTTP `200` after | PASS |
| Restore audit trail | CloudTrail restore event exists | One matching `RestoreTableToPointInTime` event | PASS |

Authoritative machine-readable evidence:

* [Result summary](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/result.json)
* [Full command transcript](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/mandate20-drill-transcript.txt)
* [Marker before controlled deletion](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/pitr-covered-marker.json)
  and [absence after deletion](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/deleted-check.json)
* [PITR restore request](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/restore-request.json)
  and [restored marker](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/restored-item.json)
* [Source still absent after restore](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/source-after-restore.json)
  and [CloudTrail restore event](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/cloudtrail-restore-events.json)
* [Before/after Kubernetes health files](../../scripts/drills/m20-dynamodb-evidence-20260727-115433/)
* [Console evidence index](../evidence/mandate-20/2026-07-27/README.md)

Verbatim evidence excerpt from the saved transcript:

```text
Mode=EXECUTE
MarkerId=m20-drill-20260727115433
TargetTable=m20-drill-outbox-20260727115433
PITRStatus=ENABLED
T_safe=2026-07-27T04:56:21Z
PITRCoverage=PASS
T_loss=2026-07-27T05:01:58.0000000Z
ActualRPOSeconds=337
RPO=PASS
T_restore_start=2026-07-27T05:02:20.2580926Z
RestoredDeclaredHash=92b6a3a27db9b8bf0df56a2899b213e38f1a6af5fbf969d6988faf2c23bd98d7
RestoredComputedHash=92b6a3a27db9b8bf0df56a2899b213e38f1a6af5fbf969d6988faf2c23bd98d7
ExpectedHash=92b6a3a27db9b8bf0df56a2899b213e38f1a6af5fbf969d6988faf2c23bd98d7
ActualRTOMinutes=16.77
MatchingRestoreEvents=1
SourceMarkerAbsent         : True
ProductionOverwritten      : False
StorefrontAfterHttp        : 200
Result                     : PASS
MANDATE20_DRILL=PASS
```

The formal evidence pack remains the proof of the drill outcome. The Console
screenshots were captured around 11:31-11:33 ICT, before the formal run started
at 11:54 ICT, and therefore prove backup configuration and recovery-point
availability only; they are not presented as proof of the later restore result.

### 8.2 Formal RDS controlled-loss PITR drill — PASS

The formal RDS run completed on 2026-07-27 against
`techx-prod-tf2-postgresql`. It created and dropped only the unique table
`m20_canary_20260727065332`, then restored the database to the private,
encrypted, Single-AZ instance `m20-rds-drill-20260727065332`. Production
routing and the source endpoint were never changed.

| Measure | Target | Actual | Result |
| :--- | :--- | :--- | :--- |
| RPO | `<= 5 minutes` | `272 seconds` (`4m 32s`) | PASS |
| RTO | `<= 30 minutes` | `13.11 minutes` | PASS |
| Restored payload integrity | Exact SHA-256 match | `92f824e4c53a02e3d9b63d9bfae19d37c18c8f25ba6fc2a6296c445fedfce990` | PASS |
| Controlled-loss proof | Canary absent from source after DROP and restore | `SourceCanaryAbsent=true` | PASS |
| Production isolation | Source never overwritten or cut over | `ProductionOverwritten=false` | PASS |
| Storefront availability | Healthy before and after | HTTP `200` before and HTTP `200` after | PASS |
| Restore audit trail | CloudTrail restore event exists | One matching `RestoreDBInstanceToPointInTime` event | PASS |

Authoritative evidence:

* [Result summary](../../scripts/drills/m20-rds-evidence-20260727065332/result.json)
* [Full RDS transcript](../../scripts/drills/m20-rds-evidence-20260727065332/mandate20-rds-drill-transcript.txt)
* [Canary creation](../../scripts/drills/m20-rds-evidence-20260727065332/canary-created.txt),
  [PITR-covered payload](../../scripts/drills/m20-rds-evidence-20260727065332/pitr-covered-canary.txt),
  and [controlled DROP proof](../../scripts/drills/m20-rds-evidence-20260727065332/canary-dropped.txt)
* [PITR request](../../scripts/drills/m20-rds-evidence-20260727065332/restore-request.json),
  [restored instance](../../scripts/drills/m20-rds-evidence-20260727065332/restored-instance.json),
  and [restored canary](../../scripts/drills/m20-rds-evidence-20260727065332/restored-canary.txt)
* [Source remains absent](../../scripts/drills/m20-rds-evidence-20260727065332/source-after-restore.txt)
  and [CloudTrail event](../../scripts/drills/m20-rds-evidence-20260727065332/cloudtrail-restore-events.json)
* [Before/after Kubernetes health](../../scripts/drills/m20-rds-evidence-20260727065332/)

Evidence excerpt:

```text
Mode=EXECUTE
TargetInstance=m20-rds-drill-20260727065332
CanaryTable=m20_canary_20260727065332
TargetBackupRetentionDays=0
PITRCoverage=PASS
T_safe=2026-07-27T06:56:58.0000000Z
T_loss=2026-07-27T07:01:29.5933946Z
ActualRpoSeconds=272
RPO=PASS
T_restore_start=2026-07-27T07:01:29.6080472Z
RestoredPayloadHash=92f824e4c53a02e3d9b63d9bfae19d37c18c8f25ba6fc2a6296c445fedfce990
T_integrity_confirmed=2026-07-27T07:14:36.4383750Z
ActualRtoMinutes=13.11
RTO=PASS
StorefrontAfterHttp=200
MatchingRestoreEvents=1
MANDATE20_RDS_DRILL=PASS
```

The temporary restore target used `BackupRetentionPeriod=0` because it is
short-lived evidence, not a production system of record. This avoids an
out-of-window initial automated backup delaying target usability. The
production source remained at seven-day backup retention throughout the drill.
The preceding diagnostic attempt restored correct data but measured
`30.47 minutes`; RDS Events showed that the target's inherited seven-day
retention triggered an initial backup after data restore. The rerun removed
that target-only delay without changing the RTO commitment.

### 8.3 Earlier restore initiation history

CloudTrail also proves that isolated PITR API calls had previously been
accepted:

| Event | Source | Isolated target | Restore time | API time |
| :--- | :--- | :--- | :--- | :--- |
| `RestoreDBInstanceToPointInTime` | `techx-prod-tf2-postgresql` | `techx-prod-tf2-postgresql-drill-test` | `2026-07-21T08:25:00Z` | `2026-07-21T08:32:00Z` |
| `RestoreTableToPointInTime` | `techx-prod-tf2-checkout-outbox` | `m20-drill-outbox-20260721073131` | `2026-07-21T07:31:36Z` | `2026-07-21T07:37:14Z` |

These earlier events prove isolated PITR initiation only. They do **not** prove
a controlled loss, target readiness, restored-data integrity, or achieved RTO.
The reviewed `scripts/drills/mandate-20-dynamodb-drill.ps1` implements the
complete procedure in Section 7. Its default mode is read-only preflight;
`-Execute` is required for the controlled marker write/delete and isolated
restore, with two interactive confirmations and no automatic cleanup. The
script itself is not evidence of recovery. The completed run in Section 8.1,
its recorded integrity result, measured RPO/RTO, and mentor-observed video or
session together form the formal drill evidence.

The destructive-DDL detection resources are defined in Terraform but are not
operational evidence until a production apply has completed and a controlled
canary `DROP TABLE` has produced the PostgreSQL log event, metric datapoint,
alarm transition, and delivered notification.

---

## 9. Sign-Off

| Role | Name | Decision | Date | Evidence reference |
| :--- | :--- | :--- | :--- | :--- |
| ADR author | `tientp` | Accepted / maintained | 2026-07-27 | This ADR, linked IaC, and formal DynamoDB/RDS evidence packs |
| CDO / data owner | Pending | Pending | Pending | Pending |
| BCP/DR mentor | Pending | Pending | Pending | Video/session and drill evidence pack |

The infrastructure gate and formal DynamoDB and RDS restore drills are
complete.
Directive 20 submission remains pending until the mentor-observed video/session
and mentor sign-off are recorded.

<!-- Change trail: @hungxqt - 2026-07-22 - Mark EBS hourly tags and vault RPs done. -->
<!-- Change trail: @tientp - 2026-07-27 - Record formal DynamoDB PITR PASS and evidence pack. -->
<!-- Change trail: @tientp - 2026-07-27 - Record formal RDS PITR PASS, measured RPO/RTO, and evidence pack. -->
<!-- Change trail: @tientp - 2026-07-27 - Re-verify scheduled Valkey and EBS cadence evidence after the formal drills. -->
