# Change: Private DNS for internal operator entrypoint (`internal.hungtran.id.vn/<service>`)

## Summary

Added a Terraform module and **production** wiring for a **Route 53 private hosted zone** so Client VPN operators resolve a single memorable hostname — **`internal.hungtran.id.vn`** — to the existing internal storefront ALB. Services remain path-based on frontend-proxy (`/grafana/`, `/jaeger/`, …). Development is intentionally **not** wired.

## Context

Staff reached admin UIs over Client VPN using the long internal ALB DNS name. A private zone gives a short entrypoint without publishing admin names on public DNS and without taking over the public `hungtran.id.vn` apex (which would require split-horizon for `shop`).

* Why now: improve operator UX for private admin paths.
* Constraint: reuse one internal ALB; keep Envoy path routing; production-only enablement.

## Before

* Operators used raw ALB DNS: `http://k8s-techxcor-frontend-….us-east-1.elb.amazonaws.com/grafana/`.
* No Route 53 private hosted zone for an operator entry hostname.

## After

* Module `modules/private-dns` creates (when enabled):
  * Private hosted zone **`internal.hungtran.id.vn`** associated with the production VPC.
  * Apex **Alias A** → internal storefront ALB (`cloudfront_origin_alb_arn`).
* Operator URLs (path routing unchanged):
  * `http://internal.hungtran.id.vn/grafana/`
  * `http://internal.hungtran.id.vn/jaeger/`
  * `http://internal.hungtran.id.vn/loadgen/`
  * `http://internal.hungtran.id.vn/feature/`
  * `http://internal.hungtran.id.vn/flagservice/`
* Production: `private_dns_enabled = true`.
* Development: **not** modified / not wired.

## Technical Design Decisions

* **Single hostname + paths** (`internal…/<service>`) instead of `service.hungtran.id.vn`: matches existing Envoy path routes; no app `root_url` / host-based Envoy changes; one DNS record.
* **Dedicated zone `internal.hungtran.id.vn`** (not private zone for public apex `hungtran.id.vn`): avoids split-horizon for `shop.hungtran.id.vn`; VPN clients keep public DNS for the storefront.
* **Production only:** no development environment wiring (operator request).
* **`service_paths` map is documentation/outputs only** — DNS is apex-only.

## Implementation Details

1. Created/updated `modules/private-dns` (apex alias to ALB; no per-service records; no CloudFront split-horizon).
2. Wired `module.private_dns` in **production** only.
3. Documented operator URLs in `docs/client-vpn.md` and `docs/cloudfront.md`.
4. Chart overlay comment points at `internal.hungtran.id.vn/<service>`.

## Files Changed

**Module:**

* `modules/private-dns/main.tf` — Private zone + apex Alias A to ALB.
* `modules/private-dns/variables.tf` — `zone_name`, `alb_arn`, `service_paths`, etc.
* `modules/private-dns/outputs.tf` — Hostname, base URL, service URL map, operator note.
* `modules/private-dns/versions.tf` — Provider constraints.

**Production:**

* `environments/production/main.tf` — Module wiring.
* `environments/production/variables.tf` — `private_dns_*` variables.
* `environments/production/outputs.tf` — Zone/hostname/URL outputs.
* `environments/production/terraform.tfvars` — Enabled; zone `internal.hungtran.id.vn`.

**Docs / related:**

* `docs/client-vpn.md` — Private DNS operator steps.
* `docs/cloudfront.md` — Admin path note.
* `modules/client-vpn/outputs.tf` — Operator note URL.
* `docs/changes/2026-07-14-private-dns-internal-service-names.md` — This change record.

**Chart (comment only):**

* `techx-corp-chart/values-public-alb.yaml` — Operator note for private DNS paths.

## Dependencies and Cross-Repository Impact

* Depends on existing internal ALB ARN (`cloudfront_origin_alb_arn`).
* Client VPN AmazonProvidedDNS (module default) required for laptop resolution.
* No platform/Envoy image change — path routes already exist.
* Development stack: no private DNS module wiring.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No path-routing change; new private hostname to same ALB |
| **Infrastructure** | +1 private hosted zone + 1 apex Alias A (production) |
| **Deployment** | Terraform apply production; no Helm required for DNS |
| **Performance** | Negligible |
| **Security** | Hostname not public; still requires Client VPN + app auth |
| **Reliability** | ALB recreate → update ARN + apply |
| **Cost** | ~$0.50/month private zone + low query volume |
| **Backward compatibility** | Raw ALB DNS still works |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt` (module + production) | ✅ Applied |
| Validate (prod) | `terraform -chdir=environments/production init -backend=false` + `validate` | ✅ Pass |
| Validate (dev) | (no private DNS module; stack still validates) | ✅ Pass |

### Manual Verification

Post-apply, Client VPN connected:

```cmd
nslookup internal.hungtran.id.vn
curl -i http://internal.hungtran.id.vn/grafana/
curl -i https://shop.hungtran.id.vn/grafana/
```

| Check | Expect |
|---|---|
| Internal Grafana URL on VPN | 200 or app login |
| CloudFront `/grafana/` | 403 when blocking on |
| Off VPN | `internal.hungtran.id.vn` not public |

### Remaining Verification (Post-Merge)

* Operator applies production and checks `private_dns_service_urls` output.

## Migration or Deployment Notes

1. Ensure `cloudfront_origin_alb_arn` is current.

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output private_dns_service_urls
```

2. Connect Client VPN; open `http://internal.hungtran.id.vn/grafana/`.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Stale ALB ARN after recreate | Medium | Medium | Same process as CloudFront origin update |
| Operators bookmark old per-service hostnames | Low | Low | Docs use path-based URLs only |

**Rollback:**

```hcl
private_dns_enabled = false
```

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```
