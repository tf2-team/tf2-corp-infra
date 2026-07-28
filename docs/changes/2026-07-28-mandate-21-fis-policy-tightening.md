# Change: Mandate 21 FIS Execution Role Policy Tightening and OIDC Lambda Update Permission

## Summary

Tightened the production FIS execution IAM role policy in bootstrap to enforce strict least-privilege scoping across EC2, RDS, ElastiCache, NACLs, S3 evidence logging, and KMS grant creation. Granted exact Lambda function update permissions (`lambda:GetFunction*`, `lambda:UpdateFunctionCode`) for `techx-audit-alert-router` to the Platform GitHub Actions OIDC role.

## Context

Mandate 21 requires least-privilege scoping for FIS fault injection actions to ensure experiments cannot affect unauthorized AWS resources. Platform CI/CD also requires permissions to deploy the new audit alert router Lambda function.

## Before

* FIS execution role policy used broader resource wildcards for EC2 instances, RDS databases, ElastiCache replication groups, and S3 evidence logging buckets.
* FIS execution role policy allowed `ec2:RebootInstances` action.
* OIDC ECR push role lacked permissions to update Lambda code.

## After

* Scoped `ec2:StopInstances` and `ec2:StartInstances` to instances tagged with `kubernetes.io/cluster/techx-tf2-prod = shared`. Removed `ec2:RebootInstances`.
* Scoped `rds:RebootDBInstance` strictly to `techx-prod-tf2-postgresql`.
* Scoped `elasticache:InterruptClusterAzPower` strictly to `techx-prod-tf2-cart`.
* Added `aws:RequestTag/managedByFIS = true` condition to NACL disruption actions.
* Scoped S3 evidence logging strictly to `techx-prod-tf2-immutable-audit-${account_id}` under `mandate-21/fis/*`.
* Restricted `kms:CreateGrant` with `kms:ViaService = ec2.us-east-1.amazonaws.com`.
* Added `lambda:GetFunction*` and `lambda:UpdateFunctionCode` for `techx-audit-alert-router` to production GHA OIDC role.

## Technical Design Decisions

* Enforced least privilege using resource tags (`aws:ResourceTag` and `aws:RequestTag`) and specific resource ARNs.
* Added optional `lambda_update_function_arns` variable to `github-actions-ecr` Terraform module.

## Implementation Details

1. Updated `modules/github-actions-ecr/variables.tf` and `main.tf`.
2. Updated `bootstrap/main.tf` FIS execution role policy and GHA OIDC role definition.

## Files Changed

* `modules/github-actions-ecr/variables.tf` — Added `lambda_update_function_arns` variable.
* `modules/github-actions-ecr/main.tf` — Added Lambda code update policy statement.
* `bootstrap/main.tf` — Tightened FIS execution role policy and granted Lambda update permission to GHA OIDC role.
* `docs/changes/2026-07-28-mandate-21-fis-policy-tightening.md` — This change record.

## Dependencies and Cross-Repository Impact

* `techx-corp-platform`: Requires Lambda update permission for `techx-audit-alert-router` deployment workflow.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No runtime change |
| **Infrastructure** | Tightens IAM permissions for FIS execution and GHA OIDC |
| **Deployment** | Enables GHA Lambda deployment workflow |
| **Performance** | No change |
| **Security** | Significantly narrows IAM permission boundary |
| **Reliability** | Prevents FIS experiments from affecting non-target resources |
| **Cost** | No cost change |
| **Backward compatibility** | Fully backward compatible |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Module FIS test | `terraform test` in `modules/fis-az-failover` | ✅ Pass |
| Production FIS test | `terraform test` in `environments/production` | ✅ Pass |
| Bootstrap validation | `terraform validate` in `bootstrap` | ✅ Pass |

## Migration or Deployment Notes

Apply bootstrap state changes via normal Terraform workflow.

## Risks and Rollback

**Rollback procedure:**
Revert commit in `techx-corp-infra`.

# Change trail: @hungxqt - 2026-07-28 - Mandate 21 Infra FIS policy tightening and GHA Lambda deployment permissions.
