# Change: Introduce AWS Client VPN for internal admin path access

## Summary

Added an optional Terraform module and environment wiring for **AWS Client VPN** so operators can reach the existing **internal** storefront ALB and open admin/observability paths that CloudFront blocks for the public internet. No second ALB is created; the feature is off by default.

## Context

After the internal-ALB + CloudFront VPC origin cutover, sensitive prefixes (`/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`, `/otlp-http`) return **403 at CloudFront**. The ALB itself has no path blocks and is not internet-facing. Operators needed a private network path without disabling edge path blocking or relying only on `kubectl port-forward`.

* Why now: complete private operator access for the new edge model.
* Constraint: do not fight CloudFront VPC-origin security group automation by taking exclusive ALB SG ownership via Ingress annotations.

## Before

* No Client VPN (or bastion) in `techx-corp-infra`.
* Admin UIs required port-forward or temporarily turning off CloudFront path blocks.
* Docs described CloudFront 403s but not a supported private browser path to the internal ALB.

## After

* New module `modules/client-vpn` creates (when enabled): endpoint (mutual TLS), SG, optional connection logs, one+ private subnet associations, VPC authorization rule, optional ALB SG ingress for client CIDR → TCP 80.
* Development and production wire `module.client_vpn` with `client_vpn_enabled = false` by default.
* Client CIDRs: prod `10.100.0.0/22`, dev `10.101.0.0/22` (non-overlap with VPC CIDRs).
* Operator guide: `docs/client-vpn.md`; linked from CloudFront, DEPLOYMENT, COST, and the storefront edge ADR.

## Technical Design Decisions

* **Reuse existing internal ALB:** Path surface is already full; a second Ingress would double LB cost and complicate the ADR.
* **Mutual TLS (operator PKI → ACM):** Matches operator-owned cert pattern; no IdP required for v1.
* **Split tunnel + 1 AZ association:** Lowest cost for class/demo stacks.
* **Optional `alb_security_group_ids`:** Additive SG rules only; does not set Ingress `inbound-cidrs` (avoids breaking VPC origin).
* **Disabled by default:** Safe for CI validate and existing stacks.

## Implementation Details

1. Created `modules/client-vpn` (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`).
2. Wired `module "client_vpn"` in production and development `main.tf`.
3. Added env variables/outputs/tfvars defaults and commented enable examples.
4. Documented PKI, enable sequence, dual-path verification, teardown, and cost.
5. Expanded **Prerequisites setup** for both ACM certs (Import vs Request, server vs client CA, ALB SG/subnet discovery).

## Files Changed

**Module:**

* `modules/client-vpn/main.tf` — Endpoint, SG, logs, association, auth rule, optional ALB rules.
* `modules/client-vpn/variables.tf` — Inputs including cert ARNs and ALB SG list.
* `modules/client-vpn/outputs.tf` — Endpoint id/DNS, export command, operator note.
* `modules/client-vpn/versions.tf` — Terraform/provider constraints.

**Environments:**

* `environments/production/main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`
* `environments/development/main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`

**Documentation:**

* `docs/client-vpn.md` — Operator runbook with full prerequisites setup for both ACM certs.
* `docs/cloudfront.md` — Admin access section + related link.
* `docs/adr/storefront-edge-internal-alb.md` — Client VPN role in security split table.
* `docs/DEPLOYMENT.md` — Phase pointer.
* `docs/COST.md` — Optional VPN cost line.
* `docs/changes/2026-07-13-introduce-client-vpn-for-internal-paths.md` — This change record.

## Dependencies and Cross-Repository Impact

* Runtime dependency: chart internal ALB already deployed (`values-public-alb.yaml`).
* Chart/platform: documentation-only follow-up for dual-path operator guidance (no Ingress change required).
* CloudFront path blocking remains the public control; VPN does not alter the distribution.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None while `client_vpn_enabled=false`. When enabled + connected, operators can open admin paths on internal ALB HTTP. |
| **Infrastructure** | Optional Client VPN endpoint, association, logs, optional ALB SG rules |
| **Deployment** | Explicit tfvars enable after ACM certs |
| **Performance** | N/A for public edge |
| **Security** | Public path blocks unchanged; private access gated by client certs |
| **Reliability** | Single-AZ association is a cost trade-off (no multi-AZ HA in v1) |
| **Cost** | Association + connection hours only when enabled |
| **Backward compatibility** | Fully compatible (default off) |
| **Observability** | Optional connection logging to CloudWatch |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt -recursive` | ✅ Applied |
| Validate prod | `terraform -chdir=environments/production init -backend=false && validate` | ✅ Pass |
| Validate dev | `terraform -chdir=environments/development init -backend=false && validate` | ✅ Pass |

### Manual Verification

* With `client_vpn_enabled=false`, plan creates no Client VPN resources.
* Live enable requires real ACM ARNs + optional ALB SG; verify dual curls (CloudFront 403 vs internal ALB on VPN).

### Remaining Verification (Post-Merge)

1. Import server + client CA into ACM; set tfvars; apply.
2. Export `.ovpn`, connect, curl internal ALB admin paths.
3. Confirm CloudFront still 403s admin prefixes.

## Migration or Deployment Notes

1. Keep CloudFront path blocking **on** in production.
2. Generate PKI outside git; import ACM certs.
3. Set `client_vpn_enabled = true` and cert ARNs; preferably set `client_vpn_alb_security_group_ids`.
4. Apply; export client config; connect; use **internal ALB** hostname (not the shop CloudFront alias) for admin UIs.
5. To stop charges: `client_vpn_enabled = false` and apply.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Association cost if left on | Medium | Medium | Default off; 1 AZ; teardown docs |
| Missing ALB SG rule | High if skipped | Medium | Optional module input + runbook |
| Cert leakage | Medium | High | Operator PKI; revoke/rotate CA |
| Exclusive inbound-cidrs on Ingress | Medium if misapplied | High | Documented anti-pattern |

**Rollback procedure:**

1. Set `client_vpn_enabled = false` and apply.
2. Remove any manual ALB SG rules added for VPN if not managed by Terraform.
3. Leave CloudFront path blocking enabled.
