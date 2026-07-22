# Change: EBS encryption defaults and orphan volume cleanup

## Summary

Enforces encrypted root EBS for EKS managed node groups and Karpenter nodes, documents account-level default encryption and orphan PVC volume cleanup for TechX in `us-east-1`, and records full before/after process evidence for the encryption program.

## Context

Live inventory showed account EBS encryption-by-default **disabled**, unencrypted MNG roots, unencrypted CSI PVCs, and nine detached orphan volumes from `techx-tf2`, `techx-dev`, and superseded prod StatefulSets. Karpenter roots were already encrypted at runtime; code did not declare encryption. Plan decisions: KMS `alias/aws/ebs`, snapshot-then-delete orphans, snapshot→encrypt→restore for live PVCs (chart-side SC + rebind tracked in chart change doc).

## Before

**Baseline capture (UTC):** `2026-07-22T09:48:26Z`  
**Account:** `493499579600` (`arn:aws:iam::493499579600:user/hungxqt`)  
**Region:** `us-east-1`  
**EKS clusters:** `techx-tf2-prod` only

| Metric | Baseline value |
|---|---|
| Default encryption | `false` |
| Default KMS | `alias/aws/ebs` |
| Total volumes | 18 |
| Unencrypted | 14 |
| Encrypted | 4 |
| Available (orphan candidates) | 9 |
| In-use unencrypted PVC | 3 (prometheus, grafana, opensearch) |
| In-use unencrypted MNG roots | 2 (`vol-00b19902f9be85d8f`, `vol-0e1fb6695929f44cf`) |
| Encrypted Karpenter roots | 4 (spot churn vs earlier 5) |

**Orphans (`available`, Attachments=0):**

| VolumeId | Cluster | PVC | Size |
|---|---|---|---|
| `vol-09441ba14e7a6d03b` | techx-tf2 | postgresql-data-postgresql-0 | 5 |
| `vol-032f5b903a96894ed` | techx-tf2 | valkey-cart-data-valkey-cart-0 | 2 |
| `vol-02a0ccd04b592c5f2` | techx-tf2 | kafka-data-kafka-0 | 5 |
| `vol-00586f3fddb2f589a` | techx-dev | postgresql-data-postgresql-0 | 5 |
| `vol-02041908660d2fd83` | techx-dev | valkey-cart-data-valkey-cart-0 | 2 |
| `vol-0f1a26aca132626ab` | techx-dev | kafka-data-kafka-0 | 5 |
| `vol-0558dae370515a86b` | techx-tf2-prod | postgresql-data-postgresql-0 | 5 |
| `vol-01d0b18b29df61798` | techx-tf2-prod | kafka-data-kafka-0 | 5 |
| `vol-04a20efd8430e5532` | techx-tf2-prod | valkey-cart-data-valkey-cart-0 | 2 |

**Code before:**

* `modules/eks/main.tf` launch template root EBS: no `encrypted = true`.
* `modules/karpenter/.../ec2nodeclass.yaml`: no `blockDeviceMappings`.

## After

### Code (this commit)

* MNG launch template root EBS: `encrypted = true` (uses account default KMS / `alias/aws/ebs`).
* Karpenter EC2NodeClass: explicit `blockDeviceMappings` gp3 20Gi `encrypted: true`.
* Helm `node_resources` passes `rootVolumeSize: "20Gi"`.

### Ops phases (fill as executed)

#### Phase 0 — Baseline

| Field | Value |
|---|---|
| Before timestamp | 2026-07-22T09:48:26Z |
| Actions | Read-only inventory only |
| After | Inventory matches table above; 9 orphans re-verified Attachment count 0 |
| Expected met | Yes |

#### Phase 1 — Orphan snapshot + delete

| Field | Value |
|---|---|
| Before timestamp | 2026-07-22T09:51:49Z |
| Before | 9 available volumes; all Attachments=0; default encryption still false |
| After snapshots (completed ~09:53:44Z) | All 9 snaps `completed` 100% (map below) |
| After deletes (~09:54:00Z) | All 9 VolumeIds deleted (`InvalidVolume.NotFound` on recheck); available count **0** |
| Expected met | **Yes** |

**VolumeId → SnapshotId map:**

| VolumeId (deleted) | SnapshotId | PVC | Cluster | Size |
|---|---|---|---|---|
| `vol-09441ba14e7a6d03b` | `snap-05e7f98bbca6809d4` | postgresql-data-postgresql-0 | techx-tf2 | 5 |
| `vol-0558dae370515a86b` | `snap-058fcf0bd3714f7da` | postgresql-data-postgresql-0 | techx-tf2-prod | 5 |
| `vol-032f5b903a96894ed` | `snap-020f0c8a1cab86f3f` | valkey-cart-data-valkey-cart-0 | techx-tf2 | 2 |
| `vol-01d0b18b29df61798` | `snap-0de8c83983fc4ccf9` | kafka-data-kafka-0 | techx-tf2-prod | 5 |
| `vol-00586f3fddb2f589a` | `snap-0e6072d25fbdf5356` | postgresql-data-postgresql-0 | techx-dev | 5 |
| `vol-02a0ccd04b592c5f2` | `snap-0215bcca874d2f588` | kafka-data-kafka-0 | techx-tf2 | 5 |
| `vol-04a20efd8430e5532` | `snap-0773bb3c2a55fbbe4` | valkey-cart-data-valkey-cart-0 | techx-tf2-prod | 2 |
| `vol-02041908660d2fd83` | `snap-0da49b77e78df53c5` | valkey-cart-data-valkey-cart-0 | techx-dev | 2 |
| `vol-0f1a26aca132626ab` | `snap-0698f4ea78687c7d7` | kafka-data-kafka-0 | techx-dev | 5 |

Snapshots tagged `Purpose=ebs-encrypt-2026-07`, `RetainUntil=2026-08-05`.

#### Phase 2.1 — Default encryption

| Field | Value |
|---|---|
| Before | `EbsEncryptionByDefault=false` (09:51:49Z) |
| Actions | `enable-ebs-encryption-by-default`; `modify-ebs-default-kms-key-id alias/aws/ebs` |
| After timestamp | 2026-07-22T09:54:34Z |
| After | `EbsEncryptionByDefault=true`; KMS key `arn:aws:kms:us-east-1:493499579600:key/95a1cd2e-9394-4c27-96af-279945336c09` (AWS managed EBS default) |
| Expected met | **Yes** |

#### Phase 2.2 — Terraform apply LT / Karpenter (CI runner only)

**Apply path:** production changes are applied by GitHub Actions **Promote Production** (`terraform-promote-production.yml` → `terraform-apply.yml` on `main`), **not** local `terraform apply`.

| Field | Value |
|---|---|
| Before | Code committed on `main` (`e8d2152`); cluster may still have pre-apply LT/NodeClass |
| Trigger | push to `main` paths `modules/**` → [Promote Production run 29909739406](https://github.com/tf2-team/tf2-corp-infra/actions/runs/29909739406) (started ~2026-07-22T09:53:05Z) |
| Plan job | **success** (~24s) |
| Apply job | **success** (~8m2s); overall conclusion **success** |
| After | Runner applied production; LT `encrypted=true` + Karpenter EC2NodeClass mapping from modules |
| Local apply | **Not used** (infra applies only via repo CI runner) |

#### Phase 2.3 — MNG node roll

| Field | Value |
|---|---|
| Before roots | Included `vol-00b19902f9be85d8f`, `vol-0e1fb6695929f44cf` Encrypted=false |
| Progress | Account default encryption + CI LT update + ASG churn replaced unencrypted MNG roots |
| After (~10:58Z) | **Zero** unencrypted MNG/node roots; all in-use volumes encrypted |

#### Phase 4/5 live PVC + end state

PVC encrypt-migrate detail: `techx-corp-chart/docs/changes/2026-07-22-encrypted-storageclass-and-pvc-sc.md`.

| Metric | Baseline (09:48:26Z) | After A+B (09:54:34Z) | Final end (~10:58Z) |
|---|---|---|---|
| Default encryption | false | **true** | **true** |
| Total volumes | 18 | **13** | **11** |
| Unencrypted | 14 | **5** | **0** |
| Encrypted | 4 | **8** | **11** |
| Available orphans | 9 | **0** | **0** |

**Apply path note:** production Terraform is applied only by the infra repo CI runner (`Promote Production` on `main`), never local `terraform apply`.

## Technical Design Decisions

* **AWS managed `alias/aws/ebs`** — simplest ops; matches existing Karpenter encrypted roots; no CMK policy work.
* **Declare encryption in LT + EC2NodeClass** even after default-on — explicit IaC, survives accidental default disable.
* **Orphans: snapshot then delete** — recoverability for 14 days (`RetainUntil` tag target ~2026-08-05).
* **Live PVC migration** is operational (snapshot→encrypt→static PV rebind); chart supplies `gp3-encrypted` SC — see related chart change doc.
* Account default encryption remains an **approved CLI** step (not incomplete Terraform).

## Implementation Details

1. Captured live baseline (Phase 0) into this document.
2. Set `encrypted = true` on `aws_launch_template.node` root EBS in `modules/eks/main.tf`.
3. Added `blockDeviceMappings` + `rootVolumeSize` to Karpenter node-resources chart; pass size from `helm_release.node_resources`.
4. **Done (approved):** Phase 1 orphan snapshot+delete (9 volumes); Phase 2.1 default encryption enabled.
5. Operator steps remaining (each requires explicit approval before run):
   * Terraform apply production for LT/Karpenter (Phase 2.2).
   * MNG rolling replace for any remaining unencrypted roots (Phase 2.3).
   * Chart Argo sync + Phase 4 PVC migrations.

### Phase 1 commands (CMD; run only after approval)

Snapshot pattern (repeat per volume):

```cmd
aws ec2 create-snapshot --region us-east-1 --volume-id vol-XXXX --description "orphan-pre-delete PVC-NAME cluster-NAME" --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=orphan-PVC-NAME},{Key=Purpose,Value=ebs-encrypt-2026-07},{Key=SourceVolume,Value=vol-XXXX},{Key=RetainUntil,Value=2026-08-05}]"
```

Delete only after snap `completed` and volume still `available` with no attachments:

```cmd
aws ec2 delete-volume --region us-east-1 --volume-id vol-XXXX
```

### Phase 2.1 commands (CMD; run only after approval)

```cmd
aws ec2 enable-ebs-encryption-by-default --region us-east-1
aws ec2 modify-ebs-default-kms-key-id --region us-east-1 --kms-key-id alias/aws/ebs
aws ec2 get-ebs-encryption-by-default --region us-east-1
```

## Files Changed

**Terraform / modules:**

* `modules/eks/main.tf` — root EBS `encrypted = true` on node launch template.
* `modules/karpenter/main.tf` — pass `rootVolumeSize` into node-resources Helm values.
* `modules/karpenter/charts/node-resources/templates/ec2nodeclass.yaml` — encrypted gp3 root mapping.
* `modules/karpenter/charts/node-resources/values.yaml` — `rootVolumeSize: 20Gi`.

**Documentation:**

* `docs/changes/2026-07-22-ebs-encryption-and-orphan-cleanup.md` — this process log.

## Dependencies and Cross-Repository Impact

* Related: `techx-corp-chart/docs/changes/2026-07-22-encrypted-storageclass-and-pvc-sc.md` — StorageClass `gp3-encrypted` and chart SC defaults; required before/for Phase 4 PVC rebind.
* Terraform apply must land before MNG roll sees encrypted LT.
* Karpenter Helm release update applies EC2NodeClass (may not replace existing encrypted nodes).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No app logic change; MNG roll and PVC migrate cause short infra/obs downtime when ops run |
| **Infrastructure** | Encrypted roots for new MNG/Karpenter nodes; optional account default encryption |
| **Deployment** | Requires production Terraform apply + approved AWS CLI phases |
| **Security** | New node disks encrypted; orphans removed after snap |
| **Cost** | Orphan delete saves ~36 GiB gp2; temporary snapshot storage ~14 days |
| **Backward compatibility** | Existing unencrypted volumes unchanged until ops migrate/roll |
| **Observability** | PVC migrate (Phase 4) affects Prometheus/Grafana/OpenSearch when executed |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Baseline inventory | `aws ec2 describe-volumes` (us-east-1) | Captured 2026-07-22T09:48:26Z |
| Terraform fmt/validate | Operator after apply path | Pending apply |

### Manual Verification

* Phase 0 inventory recorded above.
* Code review: LT and EC2NodeClass declare encryption.

### Remaining Verification (Post-Merge)

* Approve and run Phase 1, 2.1; record after-state tables.
* `terraform apply` production; roll MNG; verify new roots `Encrypted=true`.
* Complete chart SC + Phase 4; fill End state table.
* After 14 days: delete tagged orphan/migration snapshots.

## Migration or Deployment Notes

1. Merge/apply infra code (this repo) to production.
2. With approval, enable default EBS encryption (2.1).
3. With approval, Phase 1 orphan cleanup.
4. Roll MNG nodes one AZ at a time; confirm encrypted roots.
5. Coordinate chart Argo sync for `gp3-encrypted` before PVC migrate.
6. Phase 4 PVC migrate per chart runbook; update End state here.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Delete wrong volume | Low | High | Only listed available IDs; snaps first |
| TF apply node disruption | Medium | Medium | Stagger MNG roll; Karpenter capacity |
| EC2NodeClass change forces node churn | Low | Medium | Disruption budgets; monitor Karpenter |

**Rollback procedure:**

* Revert LT `encrypted` / EC2NodeClass mapping via Git + apply (new nodes follow).
* Restore orphan from snapshot: `create-volume` from snap.
* Disable default encryption only if required: `aws ec2 disable-ebs-encryption-by-default --region us-east-1` (not recommended).

<!-- Change trail: @hungxqt - 2026-07-22 - EBS encryption code and process log with baseline before state. -->
