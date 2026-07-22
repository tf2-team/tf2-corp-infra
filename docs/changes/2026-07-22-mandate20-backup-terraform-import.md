# Change: Import Mandate 20 AWS Backup vault, plans, and EBS selection into Terraform

## Summary

Added module `modules/mandate20-backup` and wired it into production, then
imported the live Mandate 20 AWS Backup stack (KMS key, locked vault, service
role, daily managed-store plan/selection, hourly EBS plan/selection) into
production remote state. Targeted apply only aligned tags (0 add / 0 destroy).

## Context

The EBS hourly plan `techx-prod-tf2-mandate20-ebs-hourly` and selection
`tagged-persistent-ebs-volumes` existed only in AWS (out of band). Mandate 20
required bringing them under Terraform ownership. Related vault, KMS, IAM role,
and daily plan were imported together so dependencies stay coherent.

## Before

* No `aws_backup_*` resources in code or production state.
* Live AWS: vault `techx-prod-tf2-mandate20`, plans daily + ebs-hourly, role
  `techx-prod-tf2-mandate20-backup-service`, KMS `alias/techx-prod-tf2-backup`.

## After

**Code**

* New module `modules/mandate20-backup/` (vault lock, daily plan, EBS hourly
  plan with `Mandate20Backup=hourly` condition).
* Production `module.mandate20_backup` + outputs for vault/plan IDs.

**State (imported)**

| Address | Import ID |
|---|---|
| `module.mandate20_backup.aws_kms_key.backup` | `bcc076ad-ab55-46fd-ad16-968829a11c87` |
| `module.mandate20_backup.aws_kms_alias.backup` | `alias/techx-prod-tf2-backup` |
| `module.mandate20_backup.aws_iam_role.backup_service` | `techx-prod-tf2-mandate20-backup-service` |
| `module.mandate20_backup.aws_iam_role_policy_attachment.backup` | role + `AWSBackupServiceRolePolicyForBackup` |
| `module.mandate20_backup.aws_iam_role_policy_attachment.restore` | role + `AWSBackupServiceRolePolicyForRestores` |
| `module.mandate20_backup.aws_backup_vault.mandate20` | `techx-prod-tf2-mandate20` |
| `module.mandate20_backup.aws_backup_vault_lock_configuration.mandate20` | vault name |
| `module.mandate20_backup.aws_backup_plan.daily` | `4ccc90e9-9487-4c5a-a0c3-4bffeb2ac7d8` |
| `module.mandate20_backup.aws_backup_selection.daily_managed_stores` | planId\|selectionId |
| `module.mandate20_backup.aws_backup_plan.ebs_hourly` | `411150a4-f84c-47d8-a4c8-e264a365c21c` |
| `module.mandate20_backup.aws_backup_selection.ebs_hourly` | planId\|`d694a286-72af-490f-8738-63a2380f5e9e` |

**Apply**

* Targeted `terraform apply -target=module.mandate20_backup`: **0 added, 5
  changed (tags), 0 destroyed**.

## Technical Design Decisions

* Import full Mandate 20 backup stack (not only EBS plan) so vault/role/KMS are
  not left as untracked prerequisites.
* RDS ARNs use `db:` path segment (not `db/`) to match AWS and avoid selection
  replace.
* Tag-only apply after import; no plan/rule structural replace.

## Implementation Details

1. Authored module matching live schedules, retention, and tag condition.
2. Wired production with constructed DynamoDB/RDS ARNs for daily selection.
3. `terraform init` then sequential `terraform import`.
4. Fixed RDS ARN typo after first plan showed selection replace.
5. Applied tag alignment only.

## Files Changed

**Module:**

* `modules/mandate20-backup/main.tf`
* `modules/mandate20-backup/variables.tf`
* `modules/mandate20-backup/outputs.tf`
* `modules/mandate20-backup/versions.tf`

**Production:**

* `environments/production/main.tf` — module wire-up
* `environments/production/outputs.tf` — vault/plan outputs

**Documentation:**

* `docs/changes/2026-07-22-mandate20-backup-terraform-import.md` — this record

## Dependencies and Cross-Repository Impact

* Related workspace plan: `docs/mandate-20/IMPLEMENTATION-DEPLOYMENT-PLAN.md`
  Phase 7 “import EBS plan into Terraform” item.
* Daily selection ARNs depend on existing RDS/DDB identifiers under
  `var.project_name`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None |
| **Infrastructure** | Backup stack now Terraform-managed; tags normalized |
| **Deployment** | Future prod applies manage vault/plans; no resource recreate |
| **Reliability** | IaC ownership of backup schedule/selection |
| **Cost** | No change to schedules |
| **Backward compatibility** | Live IDs preserved via import |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Import | `terraform import` ×11 resources | Pass |
| Targeted plan (after ARN fix) | `terraform plan -target=module.mandate20_backup` | 0 add / 5 tag change / 0 destroy |
| Targeted apply | same target | 0 add / 5 change / 0 destroy |

### Manual Verification

* State lists all `module.mandate20_backup.aws_backup_*` addresses.
* Outputs: `mandate20_ebs_hourly_plan_id=411150a4-…`, vault name set.

### Remaining Verification (Post-Merge)

* Full untargeted `terraform plan` on production after merge (CI) to confirm no
  unrelated drift from this change alone.
* Commit module + production wire-up (do not commit local `*.tfplan`).

## Migration or Deployment Notes

1. Merge infra code to `main` (module already imported in production state).
2. CI plan should show no backup destroy/replace if code matches this import.
3. Do not recreate vault while recovery points exist; lock is governance mode.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Accidental destroy of vault | Low | High | No destroy in plan; prevent careless remove |
| Selection replace from ARN typo | Mitigated | High | Fixed `db:` ARNs before apply |

**Rollback procedure:**

* Code: remove module and `terraform state rm` addresses (does **not** delete AWS
  unless destroy apply).
* Do not `terraform destroy` the vault while recovery points are required.

<!-- Change trail: @hungxqt - 2026-07-22 - Document Mandate 20 backup Terraform import. -->
