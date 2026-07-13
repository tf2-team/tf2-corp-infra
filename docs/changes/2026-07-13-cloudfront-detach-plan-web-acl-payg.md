# Change: Detach CloudFront plan web ACL after PAYG switch

## Summary

Production storefront CloudFront no longer pins the flat-rate plan-created WAFv2 web ACL. After the operator cancelled the pricing plan subscription, `cloudfront_web_acl_id` is left unset so the next apply detaches the remaining `CreatedByCloudFront-*` association and returns to pay-as-you-go with optional WAF only.

## Context

Path 1 previously pinned the plan ACL so Terraform would not clear it while the flat-rate subscription was active. The operator cancelled the CloudFront pricing plan (console). On PAYG, AWS allows removing the web ACL. Keeping the ARN in `terraform.tfvars` would leave WAF attached forever and block the intended free-tier / no-WAF cost posture.

Related earlier record: `docs/changes/2026-07-13-cloudfront-keep-plan-web-acl.md` (path 1 pin; superseded for production association).

## Before

* Production `terraform.tfvars` set:
  `cloudfront_web_acl_id = "arn:aws:wafv2:us-east-1:493499579600:global/webacl/CreatedByCloudFront-fdcaf0af/…"`
* Live distribution still showed that WebACLId attached (plan cancel does not auto-detach).
* Docs described primarily the “keep plan ACL” path.

## After

* Production leaves `cloudfront_web_acl_id` unset (module default null → empty `web_acl_id` on the distribution).
* Env/module wiring for optional `cloudfront_web_acl_id` remains (future custom WAF is still one tfvars line).
* `docs/cloudfront.md` documents path A (keep plan) and path B (cancel plan → clear ACL).
* Production posture: **PAYG, no Terraform-managed WAF**.

## Technical Design Decisions

* **Unset association only; do not delete WAF in Terraform:** The plan-created ACL was never a Terraform resource. Detach via distribution `web_acl_id = ""`; optional console delete of the orphan ACL is operator cleanup.
* **Keep optional `cloudfront_web_acl_id` plumbing:** Avoids a second redesign if operators later attach a self-managed WAFv2 ACL.
* **Leave `PriceClass_All` as-is:** Matches live edge footprint after the plan era; changing price class is an independent cost decision, not required for WAF detach.

## Implementation Details

1. Operator cancelled CloudFront flat-rate pricing plan in console (prerequisite; not done by Terraform).
2. Removed production `cloudfront_web_acl_id` ARN pin from `environments/production/terraform.tfvars`.
3. Updated `docs/cloudfront.md` with path A vs path B and current production choice (path B).
4. Added this change record.

## Files Changed

**Configuration:**
* `environments/production/terraform.tfvars` — Cleared plan WebACL pin; comments for PAYG + optional future WAF.

**Documentation:**
* `docs/cloudfront.md` — Path A / path B for pricing plan + WAF.
* `docs/changes/2026-07-13-cloudfront-detach-plan-web-acl-payg.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart and platform unchanged. Requires the CloudFront pricing plan to already be cancelled; otherwise apply will fail with the same InvalidArgument about mandatory web ACL.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No storefront code change; edge no longer has plan WAF rules after apply |
| **Infrastructure** | CloudFront `WebACLId` cleared on next apply; orphan plan ACL may remain until console delete |
| **Deployment** | Production terraform apply updates distribution security association |
| **Performance** | Negligible |
| **Security** | Plan-managed WAF protections removed; path-block CloudFront Function remains |
| **Reliability** | Unblocks distribution updates that previously fought plan WAF requirements |
| **Cost** | PAYG CloudFront + no included plan WAF package |
| **Backward compatibility** | Optional `cloudfront_web_acl_id` still accepted |
| **Observability** | `cloudfront_web_acl_id` output becomes null after apply |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Live WebACL before change | `aws cloudfront get-distribution --id ELZ9H0XX23S27 --query …WebACLId` | Still attached pre-apply (expected) |
| Terraform fmt/config review | Config edit only | ✅ Reviewed |

### Manual Verification

* Confirm console: distribution pricing plan is **not** subscribed (PAYG).
* After apply:

```cmd
aws cloudfront get-distribution --id ELZ9H0XX23S27 ^
  --query Distribution.DistributionConfig.WebACLId --output text
```

Expect empty output.

### Remaining Verification (Post-Merge)

1. Apply production:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

2. Confirm plan shows `web_acl_id` changing from plan ACL ARN → empty (not the reverse).
3. Optional: delete unused `CreatedByCloudFront-fdcaf0af` web ACL in WAFv2 (global) console if no longer associated.

## Migration or Deployment Notes

1. **Prerequisite:** Pricing plan already cancelled (operator completed).
2. Merge this config, then `terraform plan` / `apply` production.
3. If apply still returns InvalidArgument about pricing plan web ACL, re-check console that the plan is fully cancelled / no longer active on the distribution.
4. Do not re-pin `CreatedByCloudFront-*` unless you re-subscribe to a flat-rate plan.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Plan cancel incomplete; apply fails | Low–Medium | Medium | Wait / finish cancel in console; temporarily re-pin ARN (path A) to unblock other updates |
| Loss of plan WAF rules | High (intentional) | Medium | Path blocks remain via CloudFront Function; attach custom WAF later via `cloudfront_web_acl_id` |
| Orphan web ACL left in account | Medium | Low | Delete in WAF console after detach |

**Rollback procedure:**

1. If a flat-rate plan is re-enabled, set `cloudfront_web_acl_id` to the required plan ACL ARN and apply (path A).
2. Or set `cloudfront_web_acl_id` to any desired self-managed global WAFv2 ARN and apply.
