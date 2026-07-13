# Change: Client VPN EKS/ALB access via association security group (SG-to-SG)

## Summary

Fixed `kubectl` timeouts while connected to AWS Client VPN by changing EKS (and ALB) security group ingress from **client CIDR** to the **Client VPN association security group** (SG-to-SG). Live production was verified: TCP 443 to private API ENIs and `kubectl get ns` succeed after the association-SG rule is present.

## Context

With Client VPN connected, the EKS API hostname resolves via AmazonProvidedDNS (`10.0.0.2`) to private ENI IPs (for example `10.0.11.5`, `10.0.10.161`). Operators still saw:

```text
Unable to connect to the server: context deadline exceeded
```

even after the earlier change that opened the cluster security group to the VPN **client CIDR** (`10.100.0.0/22`).

Diagnosis on production (`techx-tf2-prod`, Client VPN `cvpn-endpoint-0199c82ca8be5f56b`):

* VPN route `10.0.0.0/16`, authorization rule, and association were healthy.
* Cluster SG already had TCP 443 from `10.100.0.0/22`.
* `Test-NetConnection` to private API IPs: **failed**.
* Internal ALB HTTP still returned **200** because another ALB SG allowed `0.0.0.0/0:80`, masking a weak client-CIDR-only model.
* Adding TCP 443 from the Client VPN association SG (`sg-0145f7ffdb005a817`) to the cluster SG made both TCP tests and `kubectl get ns` succeed immediately.

AWS Client VPN authorization guidance: allow application security groups to receive traffic from the **security group applied to the Client VPN target network association**, not only from the client CIDR.

## Before

* `modules/client-vpn` created target ingress rules with `cidr_ipv4 = var.client_cidr_block` for ALB (TCP 80) and EKS (TCP 443).
* EKS private path remained blocked for VPN clients; public endpoint still worked when DNS resolved publicly (off VPN).

## After

* ALB and EKS target ingress rules use `referenced_security_group_id = aws_security_group.client_vpn[0].id` (SG-to-SG).
* Docs and operator notes state that client CIDR alone is insufficient for private EKS API ENIs.
* Dual access unchanged: public EKS endpoint stays enabled by default.

## Technical Design Decisions

* **SG-to-SG over client CIDR:** Matches AWS Client VPN target authorization and the verified fix on production EKS ENIs.
* **Apply to ALB as well:** Same association model; avoids relying on a broad `0.0.0.0/0` ALB rule for VPN operators.
* **Keep client CIDR on the endpoint:** Still required for address assignment and routing; only the **target** SG source type changes.
* **No change to `endpoint_public_access`:** Out of scope; dual access retained.

Alternatives considered:

| Alternative | Why not |
|---|---|
| Keep client CIDR only | Proven insufficient for private EKS API in this account |
| Allow both CIDR and SG rules | Extra surface; SG-to-SG is sufficient |
| Private-only EKS API | Not requested; breaks non-VPN operators/CI |

## Implementation Details

1. Updated `aws_vpc_security_group_ingress_rule.alb_from_vpn_clients` to reference the module Client VPN SG.
2. Updated `aws_vpc_security_group_ingress_rule.eks_api_from_vpn_clients` the same way.
3. Documented root cause and troubleshooting in `docs/client-vpn.md` and `docs/DEPLOYMENT.md`.
4. Production hotfix: temporary CLI rule from association SG → cluster SG TCP 443 (to restore operator access immediately). Terraform apply will manage the durable rule; remove any duplicate manual rule after apply if present.

## Files Changed

**Module:**

* `modules/client-vpn/main.tf` — ALB/EKS ingress use association SG reference; comments.
* `modules/client-vpn/variables.tf` — Variable descriptions for SG-to-SG.
* `modules/client-vpn/outputs.tf` — Operator note updated.

**Documentation:**

* `docs/client-vpn.md` — Dual-path table, inputs, verify, troubleshooting.
* `docs/DEPLOYMENT.md` — Client VPN EKS access wording.
* `docs/changes/2026-07-13-client-vpn-eks-sg-to-sg.md` — This change record.

## Dependencies and Cross-Repository Impact

* None for chart/platform code.
* Runtime: re-apply production (and development when VPN is enabled) so state matches the SG-to-SG rules.
* Related: `docs/changes/2026-07-13-client-vpn-eks-api-access.md` (prior client-CIDR approach; superseded for target SG source type).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change to workloads |
| **Infrastructure** | Target SG rules source = Client VPN association SG |
| **Deployment** | Terraform apply on env stack with Client VPN enabled |
| **Security** | Still limited to authenticated VPN clients; SG-to-SG is AWS-recommended |
| **Reliability** | `kubectl`/Helm work while on VPN |
| **Backward compatibility** | Replaces ineffective client-CIDR target rules |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt | `terraform fmt` on module files | ✅ Applied (no further rewrites) |
| Terraform apply (prod, target client_vpn) | `terraform apply -target=module.client_vpn` | ✅ Pass — EKS rule imported/updated; ALB rules replaced to SG-to-SG |
| Live connectivity (prod) | `Test-NetConnection 10.0.11.5 -Port 443` after SG-to-SG rule | ✅ Pass |
| Live kubectl (prod) | `kubectl get ns` on Client VPN | ✅ Pass |

### Manual Verification

Before fix (client CIDR only on cluster SG):

* DNS → `10.0.11.5` / `10.0.10.161`
* TCP 443 failed; `kubectl` → context deadline exceeded

After association-SG rule:

* TCP 443 succeeded to both private API IPs
* `kubectl get ns` listed namespaces including `argocd`, `techx-corp-prod`

### Remaining Verification (Post-Merge)

1. Full (non-targeted) `terraform plan` on production to ensure no unrelated drift.
2. Development: same module change when/if Client VPN is enabled there.
3. Spot-check `kubectl get ns` off VPN (public endpoint) still works.

## Migration or Deployment Notes

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

Expect replace/update of:

* `module.client_vpn.aws_vpc_security_group_ingress_rule.eks_api_from_vpn_clients["sg-…"]`
* `module.client_vpn.aws_vpc_security_group_ingress_rule.alb_from_vpn_clients["sg-…"]` (when ALB SGs are set)

If a manual production rule was added during incident response (`Client VPN ENI SG to EKS API`), delete the duplicate after Terraform creates the managed rule:

```cmd
aws ec2 revoke-security-group-ingress --region us-east-1 --group-id <cluster-sg-id> --security-group-rule-ids <manual-sgr-id>
```

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Terraform briefly replaces rules during apply | Low | Low | Hotfix rule can remain until apply finishes |
| ALB VPN path if SG IDs not passed | Low | Medium | Keep `client_vpn_alb_security_group_ids` set |

**Rollback procedure:**

1. Revert module rules to `cidr_ipv4 = var.client_cidr_block` and apply (not recommended — EKS path fails again), **or**
2. Manually re-add association-SG → cluster SG TCP 443 if Terraform rule is removed.
