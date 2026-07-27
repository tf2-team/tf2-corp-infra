# Change: Mandate 20 state-version and CI-role protection

## Context

Post-promotion verification found two desired-state gaps:

1. `techx-prod-tf2-deny-destructive-backup` was still attached out of band to
   `GitHubTerraformProdApplyRole`, although production Terraform manages only
   the `TF2-TEAM` group attachment.
2. The versioned, KMS-encrypted Terraform state bucket did not explicitly deny
   day-to-day operators from deleting historical production state versions.

## Decision

- Give the bootstrap stack exclusive ownership of managed-policy attachments
  for `GitHubTerraformProdApplyRole` only. Its approved managed-policy set is
  `PowerUserAccess`; inline Terraform state and scoped IAM policies are not
  affected.
- Add `s3:DeleteObjectVersion` to the existing Mandate 20 deny policy for the
  exact object `production/terraform.tfstate` in the bootstrap-owned
  `techx-tf-state-<account>-<region>` bucket.
- Do not deny `s3:DeleteObject`: Terraform must continue deleting the native
  `.tflock` object, and normal state writes must remain uninterrupted.
- Keep S3 lifecycle expiration of noncurrent versions at 90 days. The explicit
  IAM deny applies to operator API calls and does not introduce Object Lock.

## Blast radius

- No application, database, cache, EKS, network, secret, or customer-path
  resource changes.
- Production environment plan: `0 add / 1 in-place change / 0 destroy`, limited
  to the Mandate 20 managed IAM policy.
- Bootstrap plan: `1 add / 0 change / 0 destroy`, adding exclusive attachment
  ownership to `GitHubTerraformProdApplyRole`.
- After bootstrap promotion, the stale backup deny policy is removed from the
  CI apply role; `PowerUserAccess` and all inline policies remain.

## Promotion order

1. Review and apply the production policy update through the normal production
   workflow.
2. Review the bootstrap plan and apply bootstrap through its approved manual
   procedure.
3. Verify `TF2-TEAM` remains attached to the Mandate 20 policy.
4. Verify `GitHubTerraformProdApplyRole` retains `PowerUserAccess` and no longer
   carries the Mandate 20 policy.
5. Verify a normal production plan can acquire/release the S3 lockfile.

No direct IAM detach or S3 mutation is part of this change.

## Post-merge correction

Live verification found that the first production expression used the
environment project name (`techx-prod-tf2`) when constructing the state bucket
ARN. The bootstrap stack uses the root project name (`techx`), so the policy
pointed at a non-existent bucket. The follow-up changes the resource ARN to the
canonical live bucket without changing the bucket, state object, or backend.
