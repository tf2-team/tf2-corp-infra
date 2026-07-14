# Change: Internal hostname HTTPS via supplied ACM ARN

## Summary

HTTPS for `https://internal.hungtran.id.vn` uses an **operator-supplied ACM certificate ARN** (same pattern as CloudFront). Terraform no longer requests ACM certificates or emits DNS validation records. Client VPN still opens ALB TCP **80 + 443**.

## Context

The previous design requested ACM in Terraform (`request_acm_certificate`) and required manual public-DNS validation CNAMEs plus chart paste. Operators prefer issuing the cert outside Terraform and **passing the ISSUED ARN**, consistent with `cloudfront_acm_certificate_arn`.

## Before

* `private_dns_request_acm_certificate` created `aws_acm_certificate`.
* Outputs included validation CNAME records and cert status.
* Multi-step request → public DNS → wait ISSUED → paste ARN.

## After

* Input: `private_dns_acm_certificate_arn` (empty = HTTP-only outputs).
* Module does not create ACM resources.
* When ARN is set, service URL outputs use `https://`.
* Chart still needs the **same ARN** on `publicAlb.certificateArn` for the ALB listener.

## Technical Design Decisions

* **Receive ARN, do not request cert:** Matches CloudFront and avoids long-running validation in apply.
* **Chart still gets ARN in values:** ALB controller reads Ingress annotations from Helm; single shared ARN value in tfvars + values-prod.
* **No ssl-redirect:** CloudFront origin remains HTTP:80.

## Implementation Details

1. Replaced ACM request resource with `acm_certificate_arn` variable on `modules/private-dns`.
2. Production variables/tfvars/outputs updated.
3. Docs TLS section rewritten for supply-ARN flow.
4. Client VPN multi-port ALB rules retained.

## Files Changed

* `modules/private-dns/main.tf`, `variables.tf`, `outputs.tf`
* `environments/production/main.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars`
* `docs/client-vpn.md`
* `docs/changes/2026-07-14-internal-hostname-https-acm.md` — This change record.

## Dependencies and Cross-Repository Impact

* Chart: set `components.frontend-proxy.publicAlb.certificateArn` to the same ARN.
* Related chart change: Ingress HTTPS when `certificateArn` non-empty.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | HTTPS when ARN set on both Terraform outputs and chart Ingress |
| **Infrastructure** | No ACM resource ownership in this stack |
| **Deployment** | Issue cert → set ARN in tfvars + values-prod → apply + sync |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Validate | `terraform -chdir=environments/production validate` | (run on implement) |

### Manual Verification

1. Issue ACM cert for `internal.hungtran.id.vn` (ISSUED).
2. Set `private_dns_acm_certificate_arn` and chart `certificateArn`.
3. On VPN: `curl -i https://internal.hungtran.id.vn/grafana/`

## Migration or Deployment Notes

```cmd
REM After ACM cert is ISSUED:
REM 1) Set private_dns_acm_certificate_arn in production terraform.tfvars
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan

REM 2) Set the same ARN on chart values-prod publicAlb.certificateArn → Argo sync
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| ARN set in tfvars but not chart | Medium | Medium | Docs require both; Ingress stays HTTP until chart ARN set |

**Rollback:** clear `private_dns_acm_certificate_arn` and chart `certificateArn`.
