# Change: Keep CloudFront flat-rate plan web ACL in Terraform

## Summary

Wired an optional `cloudfront_web_acl_id` input through the storefront CloudFront module and both environments, and set production to the live plan-created WAFv2 ACL ARN so Terraform no longer attempts to clear the web ACL on distributions subscribed to a CloudFront flat-rate pricing plan.

## Context

`terraform apply` failed updating CloudFront distribution `ELZ9H0XX23S27` with:

```text
InvalidArgument: You can't remove or replace the web ACL for your distribution.
Distributions with a pricing plan subscription must have a web ACL resource.
```

The distribution is on a CloudFront flat-rate pricing plan, which mandates an attached web ACL. Terraform previously left `web_acl_id` unset (null/empty), so `UpdateDistribution` tried to remove the plan ACL. Operators chose path 1: keep the pricing plan and pin the existing ACL in config.

## Before

* Module `modules/cloudfront-alb` supported optional `web_acl_id` but environments never passed it.
* Production `terraform.tfvars` had no web ACL ARN; planned updates cleared the live ACL.
* Docs treated WAF as always off for free-tier cost posture without calling out flat-rate plan constraints.

## After

* Env variable `cloudfront_web_acl_id` is wired into `module.cloudfront_storefront` (dev + prod).
* Production tfvars sets the live plan ACL:
  `arn:aws:wafv2:us-east-1:493499579600:global/webacl/CreatedByCloudFront-fdcaf0af/386dc339-d89e-4b2f-933d-0a00e8128659`
* Production `cloudfront_price_class` aligned to live `PriceClass_All` (plan-reported value; was `PriceClass_200`).
* Module validates global WAFv2 ARN shape; outputs expose `web_acl_id` / `cloudfront_web_acl_id`.
* `docs/cloudfront.md` documents the pricing-plan + web ACL requirement and discovery command.

## Technical Design Decisions

* **Pin existing plan ACL (do not create WAF in Terraform):** The ACL name `CreatedByCloudFront-*` is plan-managed. Creating a parallel `aws_wafv2_web_acl` would fight the plan and still risk replace errors.
* **Optional for PAYG:** Default remains null so classic pay-as-you-go distributions can stay WAF-free.
* **Association-only management:** Terraform only sets `web_acl_id` on the distribution; lifecycle of the plan ACL stays with AWS / the pricing plan.

## Implementation Details

1. Extended module `web_acl_id` description + ARN validation; normalize null → empty string for the resource argument.
2. Added `cloudfront_web_acl_id` to development and production `variables.tf`, `main.tf` module call, and outputs.
3. Set production `terraform.tfvars` from live `get-distribution` WebACLId for `ELZ9H0XX23S27`.
4. Aligned production `cloudfront_price_class` to live `PriceClass_All` to avoid unrelated drift on apply.
5. Documented flat-rate plan behavior, inputs, and tfvars example in `docs/cloudfront.md`.
6. Recorded this change under `docs/changes/`.

## Files Changed

**Module:**
* `modules/cloudfront-alb/main.tf` — Comment + null-safe `web_acl_id` assignment.
* `modules/cloudfront-alb/variables.tf` — Flat-rate plan guidance and ARN validation.
* `modules/cloudfront-alb/outputs.tf` — `web_acl_id` output.

**Environments:**
* `environments/production/variables.tf` — `cloudfront_web_acl_id`.
* `environments/production/main.tf` — Pass `web_acl_id` into module.
* `environments/production/outputs.tf` — `cloudfront_web_acl_id` + bootstrap note step.
* `environments/production/terraform.tfvars` — Live plan WebACL ARN.
* `environments/development/variables.tf` — Same variable (parity).
* `environments/development/main.tf` — Same module wiring.
* `environments/development/outputs.tf` — Same output/bootstrap note.
* `environments/development/terraform.tfvars` — Commented example.

**Documentation:**
* `docs/cloudfront.md` — Flat-rate plan section, input/output tables, tfvars example.
* `docs/changes/2026-07-13-cloudfront-keep-plan-web-acl.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart and platform are unchanged. No new AWS resources are created by Terraform for WAF; only the distribution association is declared.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No storefront behavior change; edge WAF remains the plan-created ACL |
| **Infrastructure** | Terraform state/config now tracks the existing WebACL association |
| **Deployment** | Production apply should succeed without WebACL InvalidArgument |
| **Performance** | No change |
| **Security** | Plan WAF stays attached (required by subscription) |
| **Reliability** | Removes apply blocker on CloudFront updates |
| **Cost** | Unchanged; still on existing pricing plan + included WAF |
| **Backward compatibility** | PAYG stacks with null `cloudfront_web_acl_id` behave as before |
| **Observability** | New `cloudfront_web_acl_id` output |

## Post-merge integrity note (2026-07-13)

After merges, the **web ACL pin remained intact** end-to-end (tfvars ARN, env wiring, module assignment). A later commit on the same message (`d22b148`) accidentally deleted `geo_restriction_type` / `geo_restriction_locations` from `modules/cloudfront-alb/variables.tf` while editing `web_acl_id`, which broke `terraform validate` (`Reference to undeclared input variable`). Those geo variables were restored; `web_acl_id` validation was already restored in `b0e0fcb`.

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Live WebACL discovery | `aws cloudfront get-distribution --id ELZ9H0XX23S27 --query Distribution.DistributionConfig.WebACLId` | ✅ ARN returned (used in tfvars) |
| Terraform validate | `terraform -chdir=environments/production init -backend=false` + `validate` | ✅ Pass (after geo var restore) |
| Config vs live WebACL | production `cloudfront_web_acl_id` == AWS `WebACLId` | ✅ Match |

### Manual Verification

* Confirmed distribution comment `techx-prod-tf2 storefront`, alias `shop.hungtran.id.vn`, WebACLId `CreatedByCloudFront-fdcaf0af`.

### Remaining Verification (Post-Merge)

1. From `techx-corp-infra`:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
```

2. Confirm plan does **not** show `web_acl_id` changing to empty/null (should match live ARN or show no change).
3. Apply when ready; re-run a non-destructive CloudFront update path if needed.

## Migration or Deployment Notes

1. No console changes required if the plan ACL ARN matches production tfvars (already fetched from live).
2. If the plan recreates a new ACL later, update `cloudfront_web_acl_id` from `get-distribution` before the next apply.
3. Do **not** set `cloudfront_web_acl_id = null` while the pricing plan is still active.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Plan ACL ARN rotates / renames | Low | Medium | Re-read WebACLId from AWS and update tfvars |
| Operator clears `cloudfront_web_acl_id` while plan active | Medium | High | Apply fails with same InvalidArgument; restore ARN |
| Attempt to replace with a different ACL | Low | Medium | AWS may reject replace; keep plan ACL or cancel plan first |

**Rollback procedure:**

1. Revert this change (or set `cloudfront_web_acl_id` back) only if you first **cancel the CloudFront pricing plan** and accept PAYG, **or** leave the live ACL attached outside Terraform.
2. Prefer Git revert of this commit if the only goal is to undo the config pin — but re-applying without the ARN will fail again while the plan remains active.
