# Change: Fix Client VPN ACM domain requirement and SG rule description

## Summary

Fixed two apply-time failures when enabling AWS Client VPN: (1) security group ingress rule descriptions used a Unicode arrow rejected by the EC2 API, and (2) operator docs used a bare `CN=server` leaf that ACM stores without a domain name, which `CreateClientVpnEndpoint` rejects.

## Context

Terraform apply with `client_vpn_enabled = true` failed in CI/operator runs with:

* `CreateClientVpnEndpoint` → `InvalidParameterValue: Certificate ... does not have a domain`
* `AuthorizeSecurityGroupIngress` → `InvalidParameterValue: Invalid rule description` (allowed charset is ASCII-only)

Both block endpoint creation. The module and runbook needed to match AWS constraints.

## Before

* `modules/client-vpn` ALB SG rule description: `Client VPN clients → storefront internal ALB HTTP` (Unicode `→` not in the EC2 allowed set).
* `docs/client-vpn.md` generated the server cert with `/CN=server` and no SAN; ACM often leaves `DomainName` empty for non-FQDN subjects.
* No pre-apply check documented for `Certificate.DomainName`.

## After

* ALB SG rule description is ASCII-only: `Client VPN clients to storefront internal ALB HTTP`.
* PKI runbook uses FQDN CN + SAN (`server.clientvpn.techx.local`) and documents a `describe-certificate` DomainName check before apply.
* Troubleshooting table covers both apply errors; variable description notes the FQDN domain requirement.

## Technical Design Decisions

* **ASCII SG descriptions only:** EC2 documents a fixed charset; avoid all Unicode in resource descriptions (comments may still use arrows).
* **Private FQDN for server cert:** Client VPN mutual TLS does not require a publicly resolvable name; any FQDN (e.g. `server.clientvpn.techx.local`) is enough for ACM DomainName. Matches AWS re:Post guidance (bare `server` fails; `server.domain.tld` works).
* **Docs + var description, not Terraform validation of ACM:** DomainName is an ACM property of an external ARN; Terraform cannot inspect it without a data source dependency that would fail when disabled. Operator check via CLI is sufficient.
* **No re-import automation:** Keys stay operator-owned outside git; re-generate/re-import remains a runbook step.

## Implementation Details

1. Replaced Unicode arrow in `aws_vpc_security_group_ingress_rule.alb_from_vpn_clients` description with the word `to`.
2. Updated OpenSSL server cert steps in `docs/client-vpn.md` to use FQDN CN and a `subjectAltName` ext file (CMD and sh examples).
3. Added DomainName verification commands and troubleshooting rows.
4. Clarified `server_certificate_arn` variable description with the FQDN requirement.

## Files Changed

**Module:**

* `modules/client-vpn/main.tf` — ASCII-only ALB SG rule description.
* `modules/client-vpn/variables.tf` — Server cert ARN docs mention non-empty DomainName / FQDN.

**Documentation:**

* `docs/client-vpn.md` — PKI FQDN/SAN, DomainName check, troubleshooting for both errors.
* `docs/changes/2026-07-13-fix-client-vpn-acm-domain-and-sg-description.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Operator must re-import a server certificate with an FQDN if the existing ACM cert has empty `DomainName`, then update `client_vpn_server_certificate_arn` in environment tfvars.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | None while Client VPN disabled |
| **Infrastructure** | Client VPN enablement can succeed when cert + module are correct |
| **Deployment** | Re-apply after module pull; may need new server ACM ARN |
| **Security** | Unchanged mutual TLS model; FQDN is identity metadata only |
| **Backward compatibility** | Existing ACM server certs without DomainName must be replaced; CA cert and client1 leaves unchanged if still valid |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Diff review | Manual review of description charset + docs | ✅ Pass (no live AWS apply in this change) |

### Manual Verification

* Confirmed EC2 allowed description charset excludes Unicode arrows.
* Confirmed AWS guidance: server cert needs a domain/FQDN for Client VPN.

### Remaining Verification (Post-Merge)

Operator (or CI apply) after fixing the server cert:

```cmd
cd /d techx-corp-infra
aws acm describe-certificate --region us-east-1 ^
  --certificate-arn <SERVER_ARN> ^
  --query "Certificate.DomainName" --output text
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

Expect DomainName non-empty and no SG description / CreateClientVpnEndpoint domain errors.

## Migration or Deployment Notes

1. Pull this module/docs change.
2. If apply already failed with "does not have a domain":
   * Re-generate server leaf with FQDN CN + SAN (see `docs/client-vpn.md`).
   * Import new server cert into ACM (`us-east-1`).
   * Set `client_vpn_server_certificate_arn` to the **new** ARN (keep CA ARN separate).
3. Re-run plan/apply. Partial resources from the failed apply (e.g. Client VPN SG without endpoint) are managed by Terraform and should complete on retry.
4. Optional: delete the unusable old server ACM cert after cutover to reduce console clutter.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Operator still uses old bare-CN cert ARN | Medium | Medium | DomainName check in runbook; apply fails fast with clear error |
| Incomplete failed apply leaves orphan SG | Low | Low | Re-apply or disable `client_vpn_enabled` to destroy module resources |

**Rollback procedure:**

* Module-only: revert the description string (reintroduces the SG error — not recommended).
* Operational: set `client_vpn_enabled = false` and apply to remove Client VPN resources.
