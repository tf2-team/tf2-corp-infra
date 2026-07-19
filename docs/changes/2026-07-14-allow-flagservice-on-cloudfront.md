# Change: Allow `/flagservice` on CloudFront (flagd browser EventStream)

## Summary

Removed `/flagservice` from the CloudFront sensitive-path block list so the public storefront can call flagd evaluation APIs (e.g. `POST …/flagservice/flagd.evaluation.v1.Service/EventStream`) without HTTP 403. Admin UI prefixes remain blocked.

## Context

The frontend uses `/flagservice/` via the public shop host for feature-flag evaluation (gRPC-web / EventStream). With CloudFront path blocking enabled, that prefix returned **403**, breaking flag evaluation in the browser.

* Why now: production console reports `POST …/flagservice/…/EventStream 403`.
* Related: `/otlp-http` was already unblocked for browser OTLP.

## Before

Default `cloudfront_blocked_prefixes` included `/flagservice`.

## After

* `/flagservice` is **not** in the default block list (module + production).
* Still blocked: `/grafana`, `/jaeger`, `/loadgen`, `/feature`.
* Still allowed: `/otlp-http`, `/flagservice`.

## Technical Design Decisions

* Flagd evaluation is a **storefront runtime dependency** at the public edge, not an admin UI; it belongs with `/otlp-http` as allowed path, not with Grafana/Jaeger.
* `/feature` (flagd UI) stays blocked — operator UI remains VPN-only.

## Implementation Details

1. Removed `/flagservice` from `modules/cloudfront-alb` and production `cloudfront_blocked_prefixes` defaults.
2. Updated `docs/cloudfront.md` block-list note.

## Files Changed

* `modules/cloudfront-alb/variables.tf`
* `environments/production/variables.tf`
* `docs/cloudfront.md`
* `docs/changes/2026-07-14-allow-flagservice-on-cloudfront.md` — This change record.

## Dependencies and Cross-Repository Impact

* Chart emergency `blockedPrefixes` / docs aligned in chart change document.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Browser flagd EventStream succeeds through CloudFront |
| **Infrastructure** | CloudFront Function regenerates without `/flagservice` |
| **Security** | Public flag evaluation API remains on edge (expected for demo storefront) |
| **Backward compatibility** | Additive allow; admin paths unchanged |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Validate | `terraform -chdir=environments/production validate` | Operator after edit |

### Manual Verification

```cmd
curl -i -X POST https://shop.hungtran.id.vn/flagservice/flagd.evaluation.v1.Service/EventStream
curl -i https://shop.hungtran.id.vn/grafana/
curl -i https://shop.hungtran.id.vn/feature/
```

| Check | Expect |
|---|---|
| `/flagservice/…` | Not edge **403** |
| `/grafana/`, `/feature/` | Still **403** |

### Remaining Verification (Post-Merge)

* Terraform apply production; confirm in browser network tab.

## Migration or Deployment Notes

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Public flagd API abuse | Low–Medium | Low | Expected for public storefront flags |

**Rollback:** re-add `"/flagservice"` to defaults and apply.
