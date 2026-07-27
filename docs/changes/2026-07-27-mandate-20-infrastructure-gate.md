# Change: Mandate 20 infrastructure gate verification

## Summary

On 2026-07-27 the team reconciled the remaining low-impact Mandate 20
infrastructure findings without changing application routing, replacing PVCs,
or creating standby data services.

## Live actions

1. Added `Mandate20Backup=hourly` to active encrypted Grafana EBS volume
   `vol-078bfcef3b62ce52d`.
2. Completed on-demand Grafana backup job
   `911ae849-a6c3-4b4c-9e64-416b331bf769`, producing recovery point
   `snap-0b9eb5165ae7f037b` in approximately 61 seconds.
3. Started manual Valkey preflight snapshot
   `m20-preflight-valkey-20260727-1004` from cache cluster
   `techx-prod-tf2-cart-001`; it subsequently reached `available`.
4. Applied the reviewed bootstrap exclusive managed-policy ownership resource:
   `1 added, 0 changed, 0 destroyed`.
5. Verified the post-bootstrap Terraform plan returned `No changes`.

## IAM result

`GitHubTerraformProdApplyRole` now has:

* managed policy `PowerUserAccess`;
* inline policy `GitHubTerraformProdApplyRole-terraform-iam`;
* inline policy `GitHubTerraformProdApplyRole-terraform-state`.

The out-of-band `IAMFullAccess` and
`techx-prod-tf2-deny-destructive-backup` managed attachments were removed.
The scoped inline IAM policy remains available for production resources whose
names use the `techx-tf2-prod*` prefix. The Mandate 20 deny policy remains
attached to the day-to-day operator group `TF2-TEAM` and no IAM roles.

## Availability checks

* Grafana remained `2/2 Running`.
* Cart remained fully ready.
* Valkey remained `available` with encryption at rest and in transit enabled,
  seven-day retention, and snapshot window `18:00-19:00` UTC.
* All Argo CD applications remained `Synced` and `Healthy`.

## Remaining evidence gate

The infrastructure gate is not declared fully passed until:

* AWS Backup reports the first `COMPLETED` scheduled hourly job for active
  Grafana volume `vol-078bfcef3b62ce52d`; its on-demand preflight recovery point
  is already complete;
* the first automated Valkey snapshot is retained as cadence evidence.

The formal controlled-loss/PITR drill, measured RPO/RTO, integrity proof, and
mentor/data-owner sign-off remain separate pending work.

## Scope and rollback posture

No StorageClass or PVC field was mutated, no pod was restarted, and no
production endpoint was changed. The detached historical Grafana volume
`vol-0807f3ccbbfbf3bec` remains retained and tagged during the rollback window.
Cleanup of old volumes and isolated drill resources requires a separate
approved change.

<!-- Change trail: @tientp - 2026-07-27 - Record Mandate 20 infrastructure gate reconciliation. -->
