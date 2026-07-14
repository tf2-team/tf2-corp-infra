# Change: Large Node Subnets for VPC CNI Prefix IP Headroom

## Summary

Add `/20` private node subnets per AZ and steer managed node groups plus Karpenter onto them so VPC CNI prefix delegation can allocate contiguous `/28` blocks. Legacy `/24` private subnets remain for migration but no longer receive `karpenter.sh/discovery`, preventing new capacity from landing in prefix-fragmented CIDRs that caused `failed to assign an IP address to container` on `techx-tf2-prod`.

## Context

* Production incident on cluster `techx-tf2-prod`: pods stuck `ContainerCreating` with  
  `plugin type="aws-cni" ... failed to assign an IP address to container`.
* Root cause: `ENABLE_PREFIX_DELEGATION=true` with `maxPods=110` requires free **contiguous `/28` prefixes**. Subnet `10.0.10.0/24` still showed ~80 free **single** IPs, but **zero usable free `/28`s** (all full or fragmented by primary ENI IPs). New Karpenter Spot node `ip-10-0-10-177` had ENI with **zero prefixes** → ipamd pool `total 0`.
* AWS does not allow resizing existing subnet CIDRs; durable fix is larger sibling subnets + migrate node placement (not secondary CIDR/custom networking for this stack).

## Before

* Private subnets only: `priv-1a`/`priv-1b` as `/24` (prod `10.0.10.0/24`, `10.0.11.0/24`; dev `10.1.10.0/24`, `10.1.11.0/24`).
* All private subnets tagged `karpenter.sh/discovery=<cluster>`.
* MNG `system-1a`/`system-1b` used `subnet_keys = ["priv-1a"]` / `["priv-1b"]`.
* Prefix mode + density knobs present, but subnet width insufficient under multi-node warm prefixes.

## After

* Add `priv-1a-nodes` / `priv-1b-nodes` as `/20` in free VPC space:
  * Production: `10.0.16.0/20` (1a), `10.0.32.0/20` (1b).
  * Development: `10.1.16.0/20` (1a), `10.1.32.0/20` (1b).
* MNG `subnet_keys` point at `priv-*-nodes`.
* Legacy `/24` keep cluster/internal-elb tags; `enable_karpenter_discovery = false`.
* VPC module supports per-subnet `enable_karpenter_discovery` and `enable_eks_internal_elb`.
* New outputs: `private_subnet_cidrs`, `karpenter_subnet_ids`.

## Technical Design Decisions

* **Larger primary node subnets** chosen over VPC secondary CIDR + custom networking (`ENIConfig`): lower operational complexity, no CNI custom-network recycle semantics, fits existing Karpenter discovery model.
* **Keep legacy `/24`** during migration so existing ENIs/nodes/ALBs are not force-destroyed by subnet replacement; disable discovery so Karpenter does not re-fill them.
* **Not** changing VPC primary CIDR (`10.0.0.0/16` / `10.1.0.0/16`).
* **Not** reducing `maxPods` or disabling prefix delegation (would reintroduce DaemonSet `Too many pods` pressure).
* Known limitation: existing nodes on legacy `/24` keep working until recycled; operators must drain/delete NodeClaims after apply for full relief.

## Implementation Details

1. Extended `modules/vpc` private subnet object with optional discovery/elb flags; tag merge is per-subnet.
2. Added outputs for CIDRs and Karpenter-eligible subnet map.
3. Mirrored object type on env `variables.tf` (production + development).
4. Updated both env `terraform.tfvars` with `/20` node subnets, legacy discovery off, MNG keys.
5. Documented pod-density / Karpenter / cost notes and this change record.

## Files Changed

**Module:**

* `modules/vpc/variables.tf` — per-subnet tag flags.
* `modules/vpc/main.tf` — per-subnet tag merge for private subnets.
* `modules/vpc/outputs.tf` — `private_subnet_cidrs`, `karpenter_subnet_ids`.

**Environments:**

* `environments/production/terraform.tfvars` — `/20` node subnets; MNG keys; legacy discovery false.
* `environments/production/variables.tf` — private subnet object fields.
* `environments/production/outputs.tf` — new outputs.
* `environments/development/terraform.tfvars` — same pattern for `10.1.0.0/16`.
* `environments/development/variables.tf` — private subnet object fields.
* `environments/development/outputs.tf` — new outputs.

**Documentation:**

* `docs/DEPLOYMENT.md` — subnet keys table; prefix fragmentation note; post-apply recycle steps.
* `docs/karpenter.md` — discovery only on node `/20` subnets.
* `docs/COST.md` — density note uses `/20` node subnets.
* `docs/changes/2026-07-14-large-node-subnets-prefix-ip.md` — this change record.

## Dependencies and Cross-Repository Impact

None required in chart or platform repos. Runtime depends on Terraform apply + node recycle in each environment. Client VPN / ALB stay in primary VPC CIDR (no secondary CIDR).

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | After apply + node recycle, pods can obtain IPs again on new nodes; no app code change |
| **Infrastructure** | +2 private subnets per env; route table associations via existing NAT; tag updates on legacy subnets |
| **Deployment** | MNG subnet change **replaces** managed node groups (brief system-floor roll); Karpenter new nodes use `/20` only after discovery tag update |
| **Performance** | No intentional change |
| **Security** | Same SG model; larger private CIDR space still private + NAT egress |
| **Reliability** | Removes prefix IP exhaustion failure mode that blocked sandbox creation |
| **Cost** | No new NAT/EIP; subnet CIDR size does not change AWS subnet pricing |
| **Backward compatibility** | Legacy `/24` retained; existing ENIs unchanged until nodes are terminated |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Format | `terraform fmt -recursive modules/vpc environments` | ✅ Applied |
| Validate (no backend) | `terraform -chdir=environments/production init -backend=false` + `validate` | ✅ Pass |
| Validate (dev) | same for `environments/development` | ✅ Pass |

### Manual Verification

* Live prod diagnosis (pre-change): free IPs 1a=80 but usable free `/28` = 0; bad node ENI had zero prefixes; ipamd `total 0`.
* Post-apply (operator): confirm `/20` free prefix headroom; new nodes show prefixes on primary ENI; stuck pods schedule with IPs.

### Remaining Verification (Post-Merge)

1. `terraform plan` then approved `apply` for **production** (and development when convenient).
2. Confirm discovery tags only on `priv-*-nodes`.
3. Delete/cordon Karpenter nodes still on `10.0.10.0/24` / `10.0.11.0/24` (e.g. `ip-10-0-10-177`).
4. Wait for MNG roll Ready in both AZs.
5. `kubectl get pods -A` — no prolonged `FailedCreatePodSandBox` for IP assignment.

## Migration or Deployment Notes

1. Review plan: expect create 2 subnets + RT associations, tag updates, **node group replacement** (subnet_ids change).
2. Apply during a window where brief system-node turnover is acceptable.

```cmd
cd /d techx-corp-infra
terraform -chdir=environments/production init
terraform -chdir=environments/production plan -out=tfplan-large-subnets
terraform -chdir=environments/production apply tfplan-large-subnets
```

3. After apply, recycle capacity still on legacy `/24`:

```cmd
aws eks update-kubeconfig --name techx-tf2-prod --region us-east-1
kubectl get nodes -o wide
kubectl get nodeclaim -A
REM Cordon and delete NodeClaims (or nodes) whose INTERNAL-IP is still 10.0.10.x / 10.0.11.x
kubectl cordon <node>
kubectl delete nodeclaim <name>
```

4. Verify:

```cmd
aws ec2 describe-subnets --region us-east-1 --filters "Name=cidr-block,Values=10.0.16.0/20,10.0.32.0/20" --query "Subnets[].{Cidr:CidrBlock,Free:AvailableIpAddressCount,Tags:Tags}" --output table
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

5. Development: same flow with `environments/development` and cluster `techx-dev` (`10.1.16.0/20`, `10.1.32.0/20`).

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| MNG replacement causes temporary control-plane addon disruption | Medium | Medium | Apply in maintenance window; ensure desired_size ≥ 1 per AZ; watch `aws-node` / CoreDNS |
| Old nodes remain on fragmented `/24` | Medium | High until recycle | Explicit NodeClaim/node drain after apply |
| Plan unexpectedly destroys legacy subnets | Low | High | Plan review: legacy `/24` must show **update in-place** (tags only), not destroy |
| CIDR typo overlaps existing ranges | Low | High | Validate non-overlap: 10.0.16/20 and 10.0.32/20 free in 10.0.0.0/16 |

**Rollback procedure:**

1. Revert tfvars MNG `subnet_keys` to `priv-1a`/`priv-1b` and re-enable `enable_karpenter_discovery` on legacy keys if needed; remove or leave unused `/20` subnets.
2. `terraform apply` the revert; recycle nodes back if required.
3. Do **not** delete `/20` subnets while nodes still use them.

<!-- Change trail: @hungxqt - 2026-07-14 - Large /20 node subnets for VPC CNI prefix IP headroom. -->
