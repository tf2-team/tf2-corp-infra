# Change: Introduce CloudFront free-tier edge with ALB origin

## Summary

Added an optional Terraform module and environment wiring for a free-tier-friendly CloudFront distribution that uses the existing storefront ALB as origin and an operator-supplied ACM certificate ARN for viewer HTTPS. Both development and production default to disabled until ACM ARN, ALB DNS, and aliases are provided.

## Context

The storefront is exposed via an internet-facing ALB created by AWS Load Balancer Controller from Helm Ingress `frontend-proxy-public` (HTTP:80 only). There was no CloudFront, no Terraform-managed edge TLS, and no first-class input for an ACM cert. Operators needed HTTPS at a custom domain without putting a certificate on the ALB.

## Before

* No CloudFront resources in `techx-corp-infra`.
* Storefront TLS was either absent at the edge or handled outside this repo.
* Environments only documented ALB path-blocking posture for the public Ingress.

## After

* New module `modules/cloudfront-alb` creates one `aws_cloudfront_distribution` when `enabled = true`.
* Origin is a custom origin pointing at the operator-supplied ALB DNS name (`http-only` port 80).
* Viewer certificate is the operator-supplied ACM ARN (validated to be `us-east-1`).
* Free-tier posture: `PriceClass_100`, SNI-only, CachingDisabled, no WAF/logging by default.
* Development and production wire `module.cloudfront_storefront` with `cloudfront_enabled = false` by default.
* Operator guide: `docs/cloudfront.md`.

## Technical Design Decisions

* **ALB DNS as input (not data source lookup):** ALB is K8s/controller-owned and can be recreated; tag-based discovery is brittle and couples plan to live cluster state.
* **ACM ARN as primary cert input:** Certificate lifecycle stays operator-owned; CloudFront still requires us-east-1 certs for custom domains.
* **CachingDisabled + AllViewerExceptHostHeader:** Prefer correctness for dynamic storefront/cart over edge cache hit rate; Host header stays ALB DNS for empty Ingress host.
* **No ALB lockdown in v1:** Direct ALB access remains possible; CloudFront managed prefix list / origin secret is a documented follow-up to avoid chart changes in this PR.
* **Disabled by default:** Safe for CI validate and existing stacks; enable is an explicit tfvars change.

## Implementation Details

1. Created `modules/cloudfront-alb` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`) with `enabled` count gate, managed policy data sources, and lifecycle precondition when enabled.
2. Wired `module "cloudfront_storefront"` into production and development `main.tf`.
3. Added env variables: `cloudfront_enabled`, `cloudfront_acm_certificate_arn`, `cloudfront_origin_domain_name`, `cloudfront_aliases`, `cloudfront_price_class`.
4. Exported distribution id/domain/ARN/hosted zone/status/aliases and a bootstrap note.
5. Documented enable sequence in `docs/cloudfront.md` and this change record; linked from `docs/DEPLOYMENT.md`.

## Files Changed

**Module:**

* `modules/cloudfront-alb/main.tf` — CloudFront distribution + managed cache/origin-request policies.
* `modules/cloudfront-alb/variables.tf` — Inputs including ACM ARN validation for us-east-1.
* `modules/cloudfront-alb/outputs.tf` — Distribution identifiers for DNS cutover.
* `modules/cloudfront-alb/versions.tf` — Terraform/provider constraints.

**Environments:**

* `environments/production/main.tf` — Module call.
* `environments/production/variables.tf` — CloudFront variables.
* `environments/production/outputs.tf` — CloudFront outputs.
* `environments/production/terraform.tfvars` — Disabled defaults + commented examples.
* `environments/development/main.tf` — Module call.
* `environments/development/variables.tf` — CloudFront variables.
* `environments/development/outputs.tf` — CloudFront outputs.
* `environments/development/terraform.tfvars` — Disabled defaults + commented examples.

**Documentation:**

* `docs/cloudfront.md` — Operator guide.
* `docs/DEPLOYMENT.md` — Pointer to CloudFront enablement.
* `docs/changes/2026-07-13-introduce-cloudfront-alb-origin.md` — This change record.

## Dependencies and Cross-Repository Impact

* Runtime dependency only: chart public Ingress must produce an ALB before enablement.
* No chart or platform code changes in this change.
* DNS and ACM remain outside Terraform.

None for merge of the disabled default.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None while `cloudfront_enabled=false`. When enabled + DNS cutover, clients use HTTPS via CloudFront; origin remains HTTP to ALB. |
| **Infrastructure** | Optional one CloudFront distribution per env when enabled. |
| **Deployment** | Opt-in tfvars + apply; DNS CNAME/alias after apply. |
| **Performance** | Edge TLS termination; no edge caching of dynamic content by default. |
| **Security** | HTTPS at edge with ACM; ALB still directly reachable until optional lockdown follow-up. |
| **Reliability** | CloudFront is an additional hop; ALB path remains independent rollback target. |
| **Cost** | Near-zero when disabled; when enabled, free-tier quotas then standard CloudFront pricing (PriceClass_100). |
| **Backward compatibility** | Fully backward-compatible default (disabled). |
| **Observability** | No access logging by default (cost). |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt` (module + envs) | ✅ Applied |
| Validate prod | `terraform -chdir=environments/production init -backend=false && validate` | ✅ Pass |
| Validate dev | `terraform -chdir=environments/development init -backend=false && validate` | ✅ Pass |

### Manual Verification

* With defaults (`cloudfront_enabled=false`), plan shows no CloudFront resources.
* Live enablement requires real ACM + ALB DNS (operator post-merge).

### Remaining Verification (Post-Merge)

* Operator enables per env with real values, applies, points DNS, runs `curl -I https://<alias>/`.
* Optional follow-up: restrict ALB to CloudFront managed prefix list.

## Migration or Deployment Notes

1. Prerequisites: healthy `frontend-proxy-public` Ingress; ACM cert ISSUED in `us-east-1`.
2. Set `cloudfront_*` variables in the target environment `terraform.tfvars`.
3. `terraform plan` / `apply` for that environment.
4. Point DNS to `cloudfront_domain_name`.
5. Smoke HTTPS and confirm path blocking still works for admin prefixes.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| ACM not in us-east-1 | Medium | Medium | Variable validation + docs |
| ALB DNS changes after controller recreate | Medium | Medium | Update `origin_domain_name` and re-apply |
| Sessions broken by caching | Low | High | CachingDisabled default |
| Direct ALB bypass | High (by design) | Low–Med | Document follow-up prefix-list lockdown |

**Rollback procedure:**

1. Revert DNS to ALB (or remove public CNAME).
2. Set `cloudfront_enabled = false` and apply to destroy the distribution.
