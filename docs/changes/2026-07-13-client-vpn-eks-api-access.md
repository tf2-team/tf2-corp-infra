# Change: Allow Client VPN access to EKS private API (dual public + VPN)

## Summary

Extended AWS Client VPN so operators can reach the **EKS private Kubernetes API** (TCP 443) in addition to the internal storefront ALB. The **public** EKS API endpoint is left enabled, giving dual access: `kubectl` works from the internet (public endpoint) and while connected to Client VPN (private endpoint after the new cluster security group rule).

## Context

With Client VPN connected, DNS often resolves the EKS API hostname to private ENI IPs (for example `10.0.11.5`). Traffic then hits the cluster security group, which previously only had paths for node/control-plane fabric—not the VPN **client CIDR**. Operators saw:

```text
Unable to connect to the server: dial tcp 10.0.11.5:443: i/o timeout
```

VPN was already authorized for the VPC CIDR and opened the internal ALB on TCP 80; Kubernetes API on the private path was never opened. Requirement: keep public API access and make the VPN private path work.

* Why now: unblock `kubectl`/Helm while on VPN without disabling the public endpoint.
* Constraint: additive SG rules only; do not force private-only API in this change.

## Before

* Client VPN module opened optional ALB SGs: client CIDR → TCP **80**.
* EKS defaults: `endpoint_public_access = true`, `endpoint_private_access = true`.
* On VPN, private API IPs timed out (no cluster SG ingress from client CIDR on 443).
* Off VPN, public endpoint could still work.

## After

* Client VPN module optionally opens EKS **cluster security group(s)**: client CIDR → TCP **443**.
* Production and development wire `eks_cluster_security_group_ids = [module.eks.cluster_security_group_id]` whenever the module is used (rules only create when `client_vpn_enabled = true`).
* Public EKS endpoint configuration is **unchanged** (still dual access).
* Docs describe dual-path verification for ALB and `kubectl`.

## Technical Design Decisions

* **Dual access (public + VPN), not private-only:** Matches the stated requirement; avoids locking out CI/operators that rely on the public endpoint.
* **Source = VPN client CIDR (not only VPN ENI SG):** Matches the existing ALB rule pattern and AWS Client VPN packet source addressing for clients.
* **Rule lives in `modules/client-vpn`:** Same lifecycle as ALB client rules; environments pass the cluster SG from `module.eks`.
* **No change to `endpoint_public_access` / `public_access_cidrs`:** Out of scope; defaults already allow public API.

Alternatives considered:

| Alternative | Why not now |
|---|---|
| Private-only API (`endpoint_public_access = false`) | User asked to keep public access |
| Manual one-off SG rule outside Terraform | Drift; not reproducible across envs |

## Implementation Details

1. Added module inputs `eks_cluster_security_group_ids` and `eks_api_ingress_port` (default 443).
2. Added `aws_vpc_security_group_ingress_rule.eks_api_from_vpn_clients` when VPN is enabled and SG IDs are non-empty.
3. Wired production and development `module.client_vpn` to pass `module.eks.cluster_security_group_id`.
4. Updated operator notes, `docs/client-vpn.md`, and `docs/DEPLOYMENT.md`.

## Files Changed

**Module:**

* `modules/client-vpn/main.tf` — EKS API ingress rule; header comment for dual use.
* `modules/client-vpn/variables.tf` — `eks_cluster_security_group_ids`, `eks_api_ingress_port`.
* `modules/client-vpn/outputs.tf` — Operator note includes EKS API path.

**Environments:**

* `environments/production/main.tf` — Pass cluster SG into Client VPN module.
* `environments/production/variables.tf` — `client_vpn_enabled` description includes EKS API.
* `environments/production/terraform.tfvars` — Comment on dual access.
* `environments/development/main.tf` — Same wiring as production.
* `environments/development/variables.tf` — Same description update.
* `environments/development/terraform.tfvars` — Comment on dual access.

**Documentation:**

* `docs/client-vpn.md` — Dual-path table, inputs, kubectl verify, troubleshooting.
* `docs/DEPLOYMENT.md` — Client VPN section includes EKS private API.
* `docs/changes/2026-07-13-client-vpn-eks-api-access.md` — This change record.

## Dependencies and Cross-Repository Impact

* None for chart/platform code.
* Runtime: production must `terraform apply` with `client_vpn_enabled = true` for the new SG rule to exist.
* Related prior work: `docs/changes/2026-07-13-introduce-client-vpn-for-internal-paths.md`.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | No change to workloads or storefront |
| **Infrastructure** | One (or more) cluster SG ingress rule(s): client CIDR → TCP 443 when VPN enabled |
| **Deployment** | Apply Client VPN / env stack; no chart change |
| **Security** | VPN client CIDR can reach private EKS API (in addition to existing public endpoint exposure) |
| **Reliability** | Operators can use `kubectl` on VPN without timeouts |
| **Backward compatibility** | Additive; no public endpoint removal |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Terraform fmt | `terraform fmt` on module + env wiring files | ✅ Applied |
| Module validate | `terraform -chdir=modules/client-vpn init -backend=false` + `validate` | ✅ Pass |
| Env plan/apply | `terraform -chdir=environments/production plan/apply` | Remaining — operator (needs AWS creds + state) |

### Manual Verification

After apply (production example):

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

Expect plan to create `module.client_vpn.aws_vpc_security_group_ingress_rule.eks_api_from_vpn_clients["sg-…"]`.

Then:

1. Connect Client VPN → `kubectl get ns` succeeds (no dial timeout to `10.x.x.x:443`).
2. Disconnect VPN → `kubectl get ns` still succeeds via public endpoint.

### Remaining Verification (Post-Merge)

* Operator apply in production (and development if/when VPN is enabled).
* Confirm SG rule visible on the cluster security group in EC2 console or CLI.

## Migration or Deployment Notes

1. No ACM or `.ovpn` changes required if Client VPN is already working for the ALB.
2. From `techx-corp-infra`:

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
```

3. Reconnect VPN (or keep existing session) and re-test `kubectl get ns`.
4. Development: same after setting `client_vpn_enabled = true` and cert ARNs.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Over-broad client CIDR access to API | Low | Medium | Client CIDR is VPN-only; still require IAM/EKS auth for API |
| Apply fails if cluster SG not found | Low | Low | Uses existing `module.eks.cluster_security_group_id` output |

**Rollback procedure:**

1. Remove `eks_cluster_security_group_ids` wiring or set it to `[]` in the module call, apply; **or** destroy the specific `aws_vpc_security_group_ingress_rule.eks_api_from_vpn_clients` resources.
2. Public EKS access is unaffected either way.
