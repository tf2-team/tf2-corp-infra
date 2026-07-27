# Directive 20 Evidence Index — 2026-07-27

This index links the formal DynamoDB and RDS controlled-loss/PITR evidence and
the AWS Console configuration screenshots used during the mentor walkthrough.

## Formal DynamoDB drill result

| Field | Recorded value |
| :--- | :--- |
| Result | **PASS** |
| Source | `techx-prod-tf2-checkout-outbox` |
| Isolated target | `m20-drill-outbox-20260727115433` |
| Marker | `m20-drill-20260727115433` |
| Safe restore time | `2026-07-27T04:56:21Z` |
| Loss time | `2026-07-27T05:01:58Z` |
| Actual RPO | `337 seconds`, target `<= 600 seconds` |
| Actual RTO | `16.77 minutes`, target `<= 30 minutes` |
| Integrity | Expected, declared, and computed SHA-256 hashes match |
| Source protection | Marker remained absent; production was not overwritten |
| Availability check | Storefront HTTP `200` before and after |
| Audit | One matching CloudTrail `RestoreTableToPointInTime` event |

Evidence files:

* [Result summary](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/result.json)
* [Full transcript](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/mandate20-drill-transcript.txt)
* [Marker read after PITR coverage](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/pitr-covered-marker.json)
* [Marker absent after controlled deletion](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/deleted-check.json)
* [Restore request](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/restore-request.json)
* [Restored marker](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/restored-item.json)
* [Source still absent after isolated restore](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/source-after-restore.json)
* [CloudTrail restore event](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/cloudtrail-restore-events.json)
* [Argo CD health before](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/k8s-before-argo.json)
  and [after](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/k8s-after-argo.json)
* [Checkout health before](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/k8s-before-checkout.json)
  and [after](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/k8s-after-checkout.json)
* [flagd health before](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/k8s-before-flagd.json)
  and [after](../../../../scripts/drills/m20-dynamodb-evidence-20260727-115433/k8s-after-flagd.json)

The repo copy of the CloudTrail export redacts the access-key identifier and
source IP. The EventId, event time, API name, source/target table names, restore
time, request ID, region, account, and resource ARNs remain available for audit.

Integrity anchors for the normalized repo copy:

```text
mandate20-drill-transcript.txt
SHA256 888F29A70975066A5DBB2FA5346116FEA8A86F8E1B7016E327CD07B49B26A9D7

result.json
SHA256 6E58C81CB557A74CFF19773EDE85451AF4193C92A11D92FB4C3450121D7986B7
```

## Formal RDS drill result

| Field | Recorded value |
| :--- | :--- |
| Result | **PASS** |
| Source | `techx-prod-tf2-postgresql` |
| Isolated target | `m20-rds-drill-20260727065332` |
| Canary table | `m20_canary_20260727065332` |
| Safe restore time | `2026-07-27T06:56:58Z` |
| Loss time | `2026-07-27T07:01:29Z` |
| Actual RPO | `272 seconds`, target `<= 300 seconds` |
| Actual RTO | `13.11 minutes`, target `<= 30 minutes` |
| Integrity | Restored SHA-256 `92f824e4c53a02e3d9b63d9bfae19d37c18c8f25ba6fc2a6296c445fedfce990` |
| Source protection | Canary remained absent; production was not overwritten |
| Availability check | Storefront HTTP `200` before and after |
| Audit | One matching CloudTrail `RestoreDBInstanceToPointInTime` event |

Evidence files:

* [Result summary](../../../../scripts/drills/m20-rds-evidence-20260727065332/result.json)
* [Full transcript](../../../../scripts/drills/m20-rds-evidence-20260727065332/mandate20-rds-drill-transcript.txt)
* [Canary creation](../../../../scripts/drills/m20-rds-evidence-20260727065332/canary-created.txt)
* [PITR-covered canary](../../../../scripts/drills/m20-rds-evidence-20260727065332/pitr-covered-canary.txt)
* [Controlled DROP proof](../../../../scripts/drills/m20-rds-evidence-20260727065332/canary-dropped.txt)
* [Restore request](../../../../scripts/drills/m20-rds-evidence-20260727065332/restore-request.json)
* [Restored instance](../../../../scripts/drills/m20-rds-evidence-20260727065332/restored-instance.json)
* [Restored canary](../../../../scripts/drills/m20-rds-evidence-20260727065332/restored-canary.txt)
* [Source still absent](../../../../scripts/drills/m20-rds-evidence-20260727065332/source-after-restore.txt)
* [CloudTrail restore event](../../../../scripts/drills/m20-rds-evidence-20260727065332/cloudtrail-restore-events.json)
* [Argo CD health before](../../../../scripts/drills/m20-rds-evidence-20260727065332/k8s-before-argo.json)
  and [after](../../../../scripts/drills/m20-rds-evidence-20260727065332/k8s-after-argo.json)
* [Workload health before](../../../../scripts/drills/m20-rds-evidence-20260727065332/k8s-before-workloads.json)
  and [after](../../../../scripts/drills/m20-rds-evidence-20260727065332/k8s-after-workloads.json)

Integrity anchors:

```text
mandate20-rds-drill-transcript.txt
SHA256 858BBCFBA03BCCB42559A38D46E69E36B37F39EE3ECBA17CD09B3154375B6B8E

result.json
SHA256 C7D7B1E1C110F594B502C579C20698442DAC5D34E4EC5E258E7D5ED0832BCA0E
```

The isolated RDS target uses backup retention `0` because it is a temporary
evidence resource. The production source remained private, encrypted, and at
seven-day automated-backup retention.

## AWS Console configuration evidence

The infrastructure Console screenshots were captured around 11:31-11:33 ICT,
before the formal 11:54 ICT drill. The IAM policy-simulation terminal screenshot
was captured later during live permission validation. These images prove the
visible backup and access-control configuration; the transcript and JSON files
above prove the formal drill outcome.

| Screenshot | Evidence visible |
| :--- | :--- |
| [AWS Backup vault](console/aws-backup-vault-lock-recovery-points.png) | `techx-prod-tf2-mandate20`, KMS key, Governance Vault Lock, bounded 1-5 week retention, and completed recovery points |
| [Daily managed-store plan](console/aws-backup-daily-managed-stores.png) | Daily plan, selected managed stores, completed RDS/DynamoDB jobs, and 14-day retention |
| [Hourly EBS plan](console/aws-backup-hourly-ebs-plan.png) | Hourly persistent-volume snapshot rule, tag-based EBS selection, and 7-day retention |
| [Hourly EBS jobs](console/aws-backup-hourly-ebs-jobs.png) | Completed Grafana, Prometheus, and OpenSearch EBS backup jobs |
| [DynamoDB PITR](console/dynamodb-pitr-and-backups.png) | PITR enabled with 35-day recovery period and available scheduled backups |
| [ElastiCache Valkey backups](console/elasticache-automated-snapshots.png) | At-rest/in-transit encryption, automatic backups, 7-day retention, and available snapshots |
| [Backup deletion deny policy](console/iam-deny-destructive-backup-policy.png) | Policy document denying destructive backup actions; this screenshot does not by itself prove entity attachment |
| [IAM policy simulation](console/iam-policy-simulation-explicit-deny-restore-allowed.png) | Principal `tuan`: destructive backup actions evaluate to `explicitDeny`, while RDS/DynamoDB/AWS Backup restore actions remain `allowed` |
| [Backup KMS key](console/kms-backup-key-rotation.png) | Enabled customer-managed key and 365-day automatic rotation |
| [RDS backups](console/rds-automated-backups-snapshots.png) | Seven-day automated backups, latest restorable time, backup window, and available snapshots |

Policy-simulation screenshot integrity:

```text
iam-policy-simulation-explicit-deny-restore-allowed.png
SHA256 4F9C29B4E13733A4DED23A3E058132F1E22852FD88B0234F992EC9922ADFEBB4
```

## Evidence boundary

The formal runs prove controlled marker/canary loss and point-in-time recovery
to isolated DynamoDB and RDS targets within committed RPO/RTO, exact integrity,
production non-overwrite, and before/after availability checks. They do not
perform production cutover, and they do not claim AZ/Region failover testing.
