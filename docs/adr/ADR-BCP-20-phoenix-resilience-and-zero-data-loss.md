# ADR-BCP-20: Data Backup, Recovery, and Proven PITR

* **Status:** Accepted - infrastructure gate implementation complete; hourly EBS/automated Valkey evidence and formal restore drill pending
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
| DynamoDB outbox | Continuous PITR plus daily AWS Backup | PITR 35 days; scheduled recovery point 14 days | <= 1 minute | <= 15 minutes | New table `m20-drill-outbox-<timestamp>` |
| Valkey cart | Daily snapshot window `18:00-19:00` UTC | 7 days | <= 24 hours | <= 20 minutes | New isolated replication group |
| Mem0 RDS | Continuous transaction logs plus daily automated backup | 14 days | <= 5 minutes | <= 30 minutes | New private RDS instance |
| Cluster manifests and IaC | Commit on every approved production change | Git history per repository policy | <= 1 hour | <= 60 minutes | Clean workspace and isolated reconstruction environment |
| Active operational EBS PVCs | Hourly AWS Backup selection by `Mandate20Backup=hourly` | 7 days | <= 1 hour | <= 60 minutes | New encrypted EBS volume / isolated PVC |

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

### 4.2 Must Be Completed Before the Formal Drill

* Retain the first completed automated Valkey snapshot as cadence evidence; the
  manual preflight snapshot is already `available`.
* Confirm the first scheduled hourly AWS Backup recovery point for active
  Grafana volume `vol-078bfcef3b62ce52d`; its on-demand preflight recovery
  point is already complete.
* ~~Apply the `Mandate20Backup=hourly` selection tag to approved active volumes
  and verify a completed EBS recovery point.~~ **DONE 2026-07-22:** tagged
  enc-prometheus / enc-grafana / enc-opensearch; three EBS RPs `COMPLETED` in
  vault `techx-prod-tf2-mandate20` (snaps `snap-09f3f69baa15c4ee4`,
  `snap-0a065ccc6a43156fd`, `snap-0dac46428a6cd7adc`).
  **FOLLOW-UP 2026-07-27:** Grafana was reprovisioned onto
  `vol-078bfcef3b62ce52d`; the active encrypted volume is now tagged, its
  on-demand preflight backup is complete, and it awaits its first scheduled
  hourly recovery point.
* Take final snapshots of orphan Kafka, PostgreSQL, and Valkey volumes, verify
  managed-store migration, and remove the orphan PVCs through an approved
  cleanup change.

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

## 7. Formal Restore Drill Plan (Run After Infrastructure Gate)

The formal mentor drill will use DynamoDB PITR because it can create an isolated
target without changing production application routing.

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
2. Wait until DynamoDB `LatestRestorableDateTime` is later than the marker
   insertion. Select `T_safe` after insertion and before deletion.
3. Delete only the marker and prove it is absent from the production table.
4. Record `T_loss` and `T_restore_start`.
5. Restore the table to `T_safe` as `m20-drill-outbox-<timestamp>`.
6. Poll until the isolated table is `ACTIVE`.
7. Read the marker from the isolated table and compare its full payload hash.
8. Record `T_integrity_confirmed`, calculate actual RPO/RTO, and declare PASS
   only when RPO <= 1 minute and RTO <= 15 minutes.
9. Keep the target for mentor inspection, then delete it only after evidence and
   sign-off are complete.

Required evidence includes commands and timestamps for marker creation,
controlled deletion, PITR request, target readiness, integrity query, RPO/RTO
calculation, production health, CloudTrail event, and cleanup.

---

## 8. Evidence Status

CloudTrail proves that isolated PITR API calls have previously been accepted:

| Event | Source | Isolated target | Restore time | API time |
| :--- | :--- | :--- | :--- | :--- |
| `RestoreDBInstanceToPointInTime` | `techx-prod-tf2-postgresql` | `techx-prod-tf2-postgresql-drill-test` | `2026-07-21T08:25:00Z` | `2026-07-21T08:32:00Z` |
| `RestoreTableToPointInTime` | `techx-prod-tf2-checkout-outbox` | `m20-drill-outbox-20260721073131` | `2026-07-21T07:31:36Z` | `2026-07-21T07:37:14Z` |

These events prove isolated PITR initiation only. They do **not** prove a
controlled loss, target readiness, restored-data integrity, or achieved RTO.
The reviewed `scripts/drills/mandate-20-dynamodb-drill.ps1` implements the
complete procedure in Section 7. Its default mode is read-only preflight;
`-Execute` is required for the controlled marker write/delete and isolated
restore, with two interactive confirmations and no automatic cleanup. The
script itself is not evidence of recovery: only a completed `-Execute` run,
recorded integrity result, measured RPO/RTO, and mentor observation count as
formal drill evidence.

The destructive-DDL detection resources are defined in Terraform but are not
operational evidence until a production apply has completed and a controlled
canary `DROP TABLE` has produced the PostgreSQL log event, metric datapoint,
alarm transition, and delivered notification.

---

## 9. Sign-Off

| Role | Name | Decision | Date | Evidence reference |
| :--- | :--- | :--- | :--- | :--- |
| ADR author | `tientp` | Proposed / maintained | 2026-07-22 | This ADR and linked IaC changes |
| CDO / data owner | Pending | Pending | Pending | Pending |
| BCP/DR mentor | Pending | Pending | Pending | Video/session and drill evidence pack |

The ADR is operationally complete only after the infrastructure gate, formal
restore drill, measured RPO/RTO, integrity proof, and mentor sign-off are all
recorded.

<!-- Change trail: @hungxqt - 2026-07-22 - Mark EBS hourly tags and vault RPs done. -->
