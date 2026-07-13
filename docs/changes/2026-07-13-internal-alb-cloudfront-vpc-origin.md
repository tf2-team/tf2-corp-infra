# Change: Internal storefront ALB + CloudFront VPC origin path blocking

## Summary

Moved the storefront edge model from an internet-facing ALB with optional ALB path rules to an **internal ALB** reached only via **CloudFront VPC origin**, with sensitive-path **403** enforcement in a **CloudFront Function**. Chart Ingress no longer enables path blocks by default; Terraform CloudFront module creates the VPC origin and optional block function.

## Context

The previous design exposed a public ALB (`scheme: internet-facing`) and blocked admin/telemetry prefixes with ALB fixed-response rules. CloudFront v1 used a **custom origin** to that public ALB, so the ALB remained directly reachable. The desired posture is: browsers only hit CloudFront; the ALB stays private; blocking lives at the edge.

* Why now: complete the CloudFront follow-up (lockdown) and remove public ALB attack surface.
* Constraint: ALB is still created by AWS Load Balancer Controller from Helm Ingress (not Terraform).

## Before

* Chart `publicAlb.scheme: internet-facing`; `blockSensitivePaths` true in base/prod for ALB 403 rules.
* CloudFront module used `custom_origin_config` against a public ALB DNS name.
* No VPC origin; path blocking only on the ALB Ingress template.
* Infra vars `storefront_alb_block_sensitive_paths` drove Helm `--set` for ALB blocks.

## After

* Chart defaults and overlays: `scheme: internal`, `blockSensitivePaths: false`.
* CloudFront module: `aws_cloudfront_vpc_origin` + distribution `vpc_origin_config`; optional `aws_cloudfront_function` for prefix 403s.
* New inputs: `cloudfront_origin_alb_arn`, `cloudfront_block_sensitive_paths`, `cloudfront_blocked_prefixes`.
* Helm helper outputs force `scheme=internal` and `blockSensitivePaths=false`.
* Docs: `docs/cloudfront.md` rewritten for VPC origin cutover.

## Technical Design Decisions

* **VPC origin over prefix-list lockdown of a public ALB:** Fully private origin; no public listener required.
* **CloudFront Function vs WAF for path blocks:** Free-tier friendly fixed 403 for a small static prefix list; WAF remains optional via `web_acl_id`.
* **ALB ARN as operator input:** Same pattern as ALB DNS — controller-owned resource; avoids brittle tag discovery at plan time.
* **Keep Ingress name `frontend-proxy-public`:** Avoids GitOps/Ingress rename blast radius; “public” means storefront edge path, not internet-facing ALB.
* **Emergency ALB block still optional:** Template retains `blockSensitivePaths` for break-glass without CloudFront.

## Implementation Details

1. Reworked `modules/cloudfront-alb` for VPC origin + Function; bumped AWS provider constraint to `>= 5.84.0`.
2. Wired new module inputs in development and production `main.tf`.
3. Replaced storefront ALB block Terraform variables with scheme + CloudFront block variables.
4. Updated outputs (VPC origin id, CF block posture, Helm flags without ALB blocks).
5. Production tfvars: `cloudfront_origin_alb_arn = ""` placeholder until operator fills post-cutover ARN; path blocking default on for CF.

## Files Changed

**Module:**

* `modules/cloudfront-alb/main.tf` — VPC origin, Function, distribution `vpc_origin_config`.
* `modules/cloudfront-alb/variables.tf` — ALB ARN, block toggles, timeouts.
* `modules/cloudfront-alb/outputs.tf` — VPC origin + block outputs.
* `modules/cloudfront-alb/versions.tf` — Provider `>= 5.84.0`.

**Environments:**

* `environments/production/main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`
* `environments/development/main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`

**Documentation:**

* `docs/cloudfront.md` — Operator guide for internal ALB + VPC origin.
* `docs/changes/2026-07-13-internal-alb-cloudfront-vpc-origin.md` — This change record.

## Dependencies and Cross-Repository Impact

* **Requires chart change** in the same delivery window: `techx-corp-chart` internal scheme + no ALB path blocks.
* Related: `techx-corp-chart/docs/changes/2026-07-13-internal-alb-no-path-blocks.md`
* Cutover order: chart internal ALB → collect DNS/ARN → set `cloudfront_origin_*` → terraform apply.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Public clients use CloudFront HTTPS; admin paths 403 at edge when CF blocking on |
| **Infrastructure** | VPC origin + optional Function; ALB becomes internal (recreate likely) |
| **Deployment** | Coordinated chart sync + Terraform apply; update origin DNS/ARN after ALB recreate |
| **Performance** | Similar; CachingDisabled retained |
| **Security** | ALB not internet-facing; path blocks at CloudFront |
| **Reliability** | Brief outage during ALB recreate + origin update if not sequenced carefully |
| **Cost** | VPC origin ENIs (CloudFront-managed); Function invocations; no public ALB data path |
| **Backward compatibility** | Breaking for direct public-ALB clients; DNS should already point at CloudFront |
| **Observability** | No access logging by default (unchanged) |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt` | ✅ Applied |
| Validate | `terraform -chdir=environments/development init -backend=false && validate` | ✅ Pass |
| Validate | `terraform -chdir=environments/production init -backend=false && validate` | ✅ Pass |

### Manual Verification

* With `cloudfront_enabled=false`, plan creates no CloudFront resources.
* Live cutover requires real ACM + internal ALB DNS/ARN (operator).

### Remaining Verification (Post-Merge)

1. Sync chart; confirm Ingress annotation `scheme: internal` and single path `/`.
2. Fill `cloudfront_origin_alb_arn` + DNS; apply Terraform.
3. `curl -I https://<alias>/` and `curl -I https://<alias>/grafana` (403 when blocking on).

## Migration or Deployment Notes

1. **Chart first:** deploy internal ALB (`values-public-alb.yaml`). If scheme does not flip, delete Ingress and re-sync.
2. Resolve new ALB DNS + ARN; set production/dev `terraform.tfvars`.
3. `terraform plan` / `apply` for the environment.
4. Confirm DNS still targets CloudFront domain.
5. Smoke edge paths; do not expect 403 on internal ALB DNS (private / not client path).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| ALB scheme change requires Ingress recreate | High | Medium | Documented delete+recreate; brief downtime |
| Empty `cloudfront_origin_alb_arn` with enabled=true | High if skipped | High | Precondition blocks apply; fill ARN first |
| Existing custom-origin distribution replace | Medium | Medium | Apply after internal ALB ready; short edge outage |
| VPC origin SG not updated (cross-account) | Low (same account) | High | Same-account auto SG; docs call out |

**Rollback procedure:**

1. Set `cloudfront_enabled = false` and apply (destroys CF + VPC origin + Function), **or** keep CF and restore previous origin inputs if still valid.
2. Chart: temporarily `scheme: internet-facing` + optional ALB blocks if emergency public access is required.
3. Point DNS as needed.
