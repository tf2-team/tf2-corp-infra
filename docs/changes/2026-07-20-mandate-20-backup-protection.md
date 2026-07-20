# Change: MANDATE-20 backup protection policy + Valkey snapshot retention

## Summary

Add Terraform module `backup-protection` that creates an IAM managed policy denying destructive backup/PITR actions (RDS snapshot delete, DynamoDB backup delete / PITR disable, ElastiCache snapshot delete). Wire the module into production. Parameterize ElastiCache Valkey automated snapshot retention (default **7 days**, was hardcoded 1) for Mandate 20 retention hygiene while cart RPO remains daily cadence.

## Context

Mandate 20 requires safe backups: encryption (already present), reasonable retention, and **operators must not casually delete backups**. Codebase had encryption and RDS deletion protection but no IAM deny on snapshot/PITR destruction. Valkey retained only 1 day of snapshots.

## Before

* Valkey `snapshot_retention_limit = 1` hardcoded in `modules/commerce-ha`.
* No reusable IAM policy for deny-destructive-backup.
* Operators with broad power could delete snapshots / disable DynamoDB continuous backups without an explicit deny guardrail.

## After

* `modules/backup-protection`: managed policy `${name}-deny-destructive-backup`; optional attach via `attach_role_names`.
* Production: `module.backup_protection` always creates policy; `var.backup_protection_attach_role_names` (default `[]`) for attach.
* Outputs: `backup_protection_policy_arn`, `backup_protection_policy_name`.
* Valkey retention variable default **7**; production `commerce_valkey_snapshot_retention_limit` default 7.

## Technical Design Decisions

* **Policy create always / attach optional:** avoids guessing human IAM role names in account; operators attach after apply or set tfvars list.
* **Deny-only statements** on delete/disable actions — does not grant any read/write (safe to attach alongside PowerUser-style roles; Deny wins).
* **Did not deny `rds:DeleteDBInstance`:** already covered by `deletion_protection` + prevent_destroy on commerce RDS; broader delete-instance deny can break break-glass destroy paths.
* **Did not deny `elasticache:ModifyReplicationGroup`:** would block legitimate ops; only `DeleteSnapshot`.
* Valkey RPO stays **24h** (daily snapshot); retention 7 only improves how far back restore points exist.

## Implementation Details

1. New module under `modules/backup-protection/` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
2. Production `main.tf` wire + `variables.tf` + `outputs.tf`.
3. `commerce-ha` snapshot retention/window variables.

## Files Changed

**Modules:**

* `modules/backup-protection/main.tf` — Deny policy document + policy + optional attachments.
* `modules/backup-protection/variables.tf` — name, attach_role_names, tags.
* `modules/backup-protection/outputs.tf` — policy ARN/name.
* `modules/backup-protection/versions.tf` — provider constraints.
* `modules/commerce-ha/main.tf` — use retention/window variables.
* `modules/commerce-ha/variables.tf` — `valkey_snapshot_retention_limit` default 7.

**Environment production:**

* `environments/production/main.tf` — modules commerce_ha + backup_protection.
* `environments/production/variables.tf` — Valkey retention + attach role names.
* `environments/production/outputs.tf` — policy outputs.

**Documentation:**

* `docs/changes/2026-07-20-mandate-20-backup-protection.md` — this record.

Workspace playbook (separate repo root change): `docs/mandate-20/*`.

## Dependencies and Cross-Repository Impact

* Related: workspace `docs/mandate-20/` PASS pack (ADR, runbook, mentor Q&A).
* No chart/platform code change required for this PR.
* After apply: attach policy to day-to-day operator roles if `backup_protection_attach_role_names` left empty.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None |
| **Infrastructure** | New IAM policy; Valkey keeps 7 daily snapshots (small storage cost) |
| **Deployment** | Requires production Terraform apply |
| **Security** | Improves ransomware/mistake resistance on backups when policy attached |
| **Reliability** | Longer Valkey snapshot history for restore drills |
| **Cost** | Low (extra ElastiCache snapshot days) |
| **Backward compatibility** | Additive; attach list default empty |

## Validation

### Automated Checks

| Check | Command | Result |
|---|---|---|
| Terraform validate (local) | Recommended after init | Operator-run |

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production init -backend=false
terraform -chdir=environments/production validate
```

### Manual Verification

* Plan should show: `aws_iam_policy` create; ElastiCache replication group update `snapshot_retention_limit` 1→7 (if currently 1).
* No destroy of RDS/DynamoDB data stores.

### Remaining Verification (Post-Merge)

1. `terraform plan/apply` production (user approval).
2. Attach policy to operator role(s).
3. Attempt `elasticache:DeleteSnapshot` as operator → AccessDenied (proof for mentor).
4. Preflight script from workspace docs.

## Migration or Deployment Notes

1. Merge infra PR.
2. Plan/apply production:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan-m20
terraform -chdir=environments/production apply tfplan-m20
```

3. Optional tfvars:

```hcl
backup_protection_attach_role_names = ["YourOperatorRoleName"]
commerce_valkey_snapshot_retention_limit = 7
```

4. Manual attach if list empty:

```cmd
aws iam attach-role-policy --role-name YourOperatorRoleName --policy-arn <backup_protection_policy_arn>
```

5. Do **not** attach deny policy to break-glass admin if that role must purge snapshots in emergency — document break-glass separately.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Apply updates Valkey in place | Medium | Low | Snapshot retention change is non-destructive |
| Deny policy attached to apply role by mistake | Low | Medium | Keep attach list empty for CI roles; only operator roles |
| Mentors ask for Vault Lock | Low | Low | B1b backlog |

**Rollback procedure:**

1. Detach policy from roles; remove `module.backup_protection` or set destroy.
2. Set `commerce_valkey_snapshot_retention_limit = 1` and apply if reverting retention.

<!-- Change trail: @hungxqt - 2026-07-20 - Record infra Mandate 20 backup protection and Valkey retention. -->
