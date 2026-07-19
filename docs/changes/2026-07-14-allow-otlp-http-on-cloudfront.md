# Change: Allow `/otlp-http` on CloudFront (unblock browser OTLP)

## Summary

Removed `/otlp-http` from the CloudFront sensitive-path block list so the public storefront can POST browser OTLP traces to `https://shop…/otlp-http/v1/traces` without receiving HTTP 403. Admin/UI prefixes remain blocked.

## Context

The frontend sets `PUBLIC_OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` to `/otlp-http/v1/traces` for browser RUM relative to the public shop host. After CloudFront path blocking was enabled, that path matched the Function block list and returned **403**, breaking web telemetry export.

* Why now: production browser console reports `POST …/otlp-http/v1/traces 403`.
* Constraint: keep admin paths (`/grafana`, `/jaeger`, …) blocked at the edge.

## Before

Default `cloudfront_blocked_prefixes` included `/otlp-http`. Viewer-request CloudFront Function returned 403 for any URI under that prefix.

## After

* `/otlp-http` is **not** in the default block list (module + production variable defaults).
* Allowed at public edge: OTLP HTTP via frontend-proxy → collector.
* Still blocked: `/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`.

## Technical Design Decisions

* **Allow OTLP at edge, not via VPN:** Browser clients cannot use Client VPN; path must be public.
* **Do not disable all path blocking:** Only remove the telemetry ingress prefix needed by the storefront.
* **Development env defaults left as-is** for this change (production + module defaults drive the live 403).

## Implementation Details

1. Removed `/otlp-http` from `modules/cloudfront-alb` `blocked_prefixes` default.
2. Removed `/otlp-http` from production `cloudfront_blocked_prefixes` default.
3. Documented the exception in `docs/cloudfront.md`.

## Files Changed

* `modules/cloudfront-alb/variables.tf` — Default block list without `/otlp-http`.
* `environments/production/variables.tf` — Same default for production.
* `docs/cloudfront.md` — Block list note.
* `docs/changes/2026-07-14-allow-otlp-http-on-cloudfront.md` — This change record.

## Dependencies and Cross-Repository Impact

* Chart/frontend already posts to `/otlp-http/v1/traces` (no app change required).
* Chart emergency ALB `blockedPrefixes` and overlay comments updated separately to stay aligned.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Browser OTLP POSTs succeed through CloudFront instead of 403 |
| **Infrastructure** | CloudFront Function code regenerates without `/otlp-http` prefix |
| **Deployment** | Terraform apply on production CloudFront module |
| **Security** | Slightly larger public path surface (OTLP ingest via edge); admin UIs still 403 |
| **Observability** | Restores browser trace export to the collector |
| **Backward compatibility** | Fully compatible; only loosens one block |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Validate | `terraform -chdir=environments/production validate` | Operator after apply |

### Manual Verification

```cmd
curl -i -X POST https://shop.hungtran.id.vn/otlp-http/v1/traces ^
  -H "Content-Type: application/json" -d "{}"
curl -i https://shop.hungtran.id.vn/grafana/
```

| Check | Expect |
|---|---|
| POST `/otlp-http/…` | Not edge **403** (may be 4xx from app/collector for empty body) |
| GET `/grafana/` | Still **403** at CloudFront |

### Remaining Verification (Post-Merge)

* Apply production Terraform; confirm Function association and live 403 list via browser network tab.

## Migration or Deployment Notes

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

CloudFront Function updates can take a short time to propagate to all edges.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Public OTLP spam/abuse | Medium | Low–Medium | Optional future rate limit/WAF; collector already receives in-cluster traffic |
| Accidental re-add of prefix | Low | Medium | Documented exclusion in variable descriptions |

**Rollback:** re-add `"/otlp-http"` to `cloudfront_blocked_prefixes` default and apply.
