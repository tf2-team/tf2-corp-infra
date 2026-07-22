# Change: MANDATE-20 criterion B — attach deny-destructive-backup to TF2-TEAM

## Summary

Close Mandate 20 requirement 5 criterion B (separation of duties for backups) by attaching the existing `techx-prod-tf2-deny-destructive-backup` managed policy to the day-to-day operator IAM group `TF2-TEAM`, aligning the Terraform module with the live policy document (EBS + AWS Backup denials), and supporting group attachments in code so operators with `AdministratorAccess` cannot casually delete backups or disable DynamoDB PITR.

## Context

Inventory of account `493499579600` showed:

* Policy `techx-prod-tf2-deny-destructive-backup` already existed (created 2026-07-20).
* It was attached only to `GitHubTerraformProdApplyRole` (CI apply), **not** to human operators.
* Day-to-day operators are IAM users in group `TF2-TEAM` with `AdministratorAccess` (members include `hungxqt`, teammates, `mentor-kai`).
* `iam:SimulatePrincipalPolicy` for `hungxqt` returned **allowed** for `rds:DeleteDBSnapshot`, `dynamodb:UpdateContinuousBackups`, and `elasticache:DeleteSnapshot`.

Criterion B requires operators to receive an explicit Deny. The module previously supported only role attachments; this account’s operators use a shared IAM **group**.

## Before

* Module `backup-protection` could attach only to IAM roles via `attach_role_names`.
* Production `backup_protection_attach_role_names` defaulted to `[]` and was unset in tfvars.
* Live policy (v3) already denied RDS/DDB/ElastiCache deletes plus EBS and AWS Backup destructive actions; module source was narrower (risk of Terraform drift on next apply).
* Operators in `TF2-TEAM` could delete backups despite policy existence.

## After

* Module supports `attach_group_names` (`aws_iam_group_policy_attachment`).
* Module policy document matches live v3 coverage (RDS, DynamoDB, ElastiCache, EBS, AWS Backup).
* Production tfvars: `backup_protection_attach_group_names = ["TF2-TEAM"]`, `backup_protection_attach_role_names = []`.
* After apply: every `TF2-TEAM` user inherits Deny (Deny wins over AdministratorAccess).
* Mis-attachment on `GitHubTerraformProdApplyRole` (if not in Terraform state) must be detached manually so CI apply is not unexpectedly blocked.

## Technical Design Decisions

* **Group attach over inventing operator roles:** Matches how this account actually grants human access (`TF2-TEAM` + AdministratorAccess). Creating a new least-privilege role set is a larger IAM redesign outside this criterion.
* **Keep CI apply roles unattached:** Plan intentionally sets `attach_role_names = []`. CI should not carry operator SoD denials that might surprise destroy/lifecycle paths.
* **Break-glass:** Account root or IAM principals **outside** `TF2-TEAM` without the deny policy remain able to purge backups under 4-eyes process. Mentors in `TF2-TEAM` also receive Deny (acceptable for demo).
* **Did not deny `ModifyDBInstance` / `ModifyReplicationGroup`:** Still avoid blocking legitimate ops; residual path documented.

## Implementation Details

1. Extended `modules/backup-protection` with group attachments and full deny statement set.
2. Wired `backup_protection_attach_group_names` through production variables, module call, outputs, and tfvars.
3. Documented apply, manual detach of wrong role if needed, and AccessDenied verification.

## Files Changed

**Modules:**

* `modules/backup-protection/main.tf` — Full deny statements; group policy attachments.
* `modules/backup-protection/variables.tf` — `attach_group_names`.
* `modules/backup-protection/outputs.tf` — `attached_group_names`.

**Environment production:**

* `environments/production/main.tf` — Pass `attach_group_names`.
* `environments/production/variables.tf` — New variable.
* `environments/production/outputs.tf` — Export attached role/group lists.
* `environments/production/terraform.tfvars` — Attach `TF2-TEAM`.

**Documentation:**

* `docs/changes/2026-07-21-mandate-20-backup-protection-attach.md` — This record.

## Dependencies and Cross-Repository Impact

* Related workspace docs (separate change): `docs/mandate-20/` ADR §2.6, DoD B6/B7, submission, evidence pack for criterion B.
* No chart or platform changes.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None |
| **Infrastructure** | IAM group attachment; policy document aligned |
| **Deployment** | Requires production Terraform apply |
| **Security** | Operators cannot delete backups / disable PITR; Deny beats AdministratorAccess |
| **Reliability** | Protects restore recovery points from casual wipe |
| **Cost** | None |
| **Backward compatibility** | Additive attach; CI apply role should be detached if currently attached outside desired state |
| **Observability** | IAM simulator / AccessDenied CloudTrail events on probe |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform validate | `terraform -chdir=environments/production validate` | Operator-run after init |
| IAM simulate (before) | `simulate-principal-policy` for hungxqt | allowed (pre-attach baseline) |
| IAM simulate (after) | same after apply | expected explicitDeny |

### Manual Verification

```cmd
aws iam list-entities-for-policy --policy-arn arn:aws:iam::493499579600:policy/techx-prod-tf2-deny-destructive-backup --output table
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::493499579600:user/hungxqt --action-names rds:DeleteDBSnapshot dynamodb:UpdateContinuousBackups elasticache:DeleteSnapshot --output table
```

Expected after attach: policy lists group `TF2-TEAM`; simulate shows **explicitDeny**.

Optional live probe (lab only): attempt `dynamodb update-continuous-backups ... PointInTimeRecoveryEnabled=false` as operator → AccessDenied.

### Remaining Verification (Post-Merge)

1. Production `terraform plan/apply` with approval.
2. If still attached: detach policy from `GitHubTerraformProdApplyRole`.
3. Capture evidence under workspace `docs/mandate-20/evidence/`.

## Migration or Deployment Notes

1. Review plan — expect group attachment create; policy version update if document differs; **no** RDS/DDB/Valkey data destroy.

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production init -backend-config=backend.hcl
terraform -chdir=environments/production plan -out=tfplan-m20-b
```

2. Apply only after explicit approval:

```cmd
terraform -chdir=environments/production apply tfplan-m20-b
```

3. Manual cleanup if apply role still has the policy outside Terraform:

```cmd
aws iam detach-role-policy --role-name GitHubTerraformProdApplyRole --policy-arn arn:aws:iam::493499579600:policy/techx-prod-tf2-deny-destructive-backup
```

4. Do **not** remove `AdministratorAccess` from `TF2-TEAM` as part of this change — Deny is sufficient for criterion B.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Mentors in TF2-TEAM also cannot delete backups | Medium | Low | Expected; use break-glass outside group for lifecycle purge |
| Terraform apply role still has deny attached | Medium | Low | Manual detach step above |
| Policy update fails mid-apply | Low | Low | Re-apply; policy is non-destructive Deny |

**Rollback procedure:**

```cmd
aws iam detach-group-policy --group-name TF2-TEAM --policy-arn arn:aws:iam::493499579600:policy/techx-prod-tf2-deny-destructive-backup
```

Or set `backup_protection_attach_group_names = []` and apply.

<!-- Change trail: @hungxqt - 2026-07-21 - Record Mandate 20 criterion B group attach for TF2-TEAM. -->
