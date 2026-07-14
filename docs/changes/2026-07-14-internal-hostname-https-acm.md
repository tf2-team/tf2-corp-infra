# Change: ACM + HTTPS support for `internal.hungtran.id.vn`

## Summary

Added optional **ACM certificate request** for the private operator hostname and Client VPN access to ALB **TCP 443**, so operators can terminate TLS on the internal storefront ALB at `https://internal.hungtran.id.vn` after public DNS validation and chart certificate attach. CloudFront origin stays **HTTP:80**.

## Context

Private DNS already resolves `internal.hungtran.id.vn` to the internal ALB over **HTTP**. Staff asked for HTTPS. Public ACM certs can be used on internal ALBs; validation still requires **public** DNS CNAMEs for domain ownership.

## Before

* Internal ALB: HTTP:80 only.
* Client VPN → ALB SG: TCP 80 only.
* No ACM request path for the private hostname.

## After

* `modules/private-dns`: optional `aws_acm_certificate` when `request_acm_certificate=true`; outputs ARN, status, validation CNAMEs.
* Production: `private_dns_request_acm_certificate = true` (operator validates DNS next).
* Client VPN: ALB SG rules for ports **80 and 443**.
* Chart: Ingress supports `certificateArn` → HTTPS:443 + certificate annotation (HTTP:80 retained). No ssl-redirect.

## Technical Design Decisions

* **No ALB ssl-redirect:** CloudFront VPC origin is `http-only` on port 80; redirect would break the public edge.
* **Public ACM + public DNS validation:** Private hosted zone cannot complete ACM DNS validation; validation CNAMEs go on the public `hungtran.id.vn` DNS.
* **Do not wait for validation in Terraform by default:** Avoid long-blocking applies; operator creates CNAMEs and re-checks status.
* **Chart auto dual-ports when cert set:** Empty cert + HTTPS listen-ports would break the controller; template enables HTTPS only when ARN is non-empty.

## Implementation Details

1. Extended `modules/private-dns` with ACM resource and outputs.
2. Production variables/tfvars/outputs for request + validation records.
3. Client VPN module: multi-port ALB SG rules (default 80, 443).
4. Documented operator sequence in `docs/client-vpn.md`.

## Files Changed

* `modules/private-dns/main.tf`, `variables.tf`, `outputs.tf`
* `modules/client-vpn/main.tf`, `variables.tf`, `outputs.tf`
* `environments/production/main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`
* `docs/client-vpn.md`
* `docs/changes/2026-07-14-internal-hostname-https-acm.md` — This change record.

## Dependencies and Cross-Repository Impact

* Chart: `certificateArn` annotation + dual listen when set (separate chart change).
* Operator must create **public** DNS validation records after apply.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | HTTPS available for operator host after cert + chart ARN |
| **Infrastructure** | +1 ACM cert (when requested); +ALB 443 SG rules for VPN |
| **Deployment** | Multi-step: apply → public DNS validate → chart ARN → sync |
| **Security** | TLS on private admin entry; ALB still not internet-facing |
| **CloudFront** | Unchanged (still HTTP origin :80) |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Validate | `terraform -chdir=environments/production validate` | (run on implement) |

### Manual Verification

1. Apply; output validation CNAMEs; create in public DNS.
2. Cert **ISSUED**; set chart `certificateArn`; sync.
3. On VPN: `curl -i https://internal.hungtran.id.vn/grafana/`

### Remaining Verification (Post-Merge)

* Operator completes public DNS validation and chart ARN cutover.

## Migration or Deployment Notes

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output private_dns_acm_validation_records
terraform -chdir=environments/production output private_dns_acm_certificate_arn
```

Then chart (after ISSUED): set `components.frontend-proxy.publicAlb.certificateArn` in `values-prod.yaml` and sync.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Apply blocked if validation resource waited | Low | Medium | No wait resource; status polled by operator |
| Accidental ssl-redirect | Low | High | Documented never-enable; not in template |

**Rollback:** `private_dns_request_acm_certificate = false` (destroys cert if no other dependents); remove chart `certificateArn`.
