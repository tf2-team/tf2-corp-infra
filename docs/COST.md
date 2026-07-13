# Cost Estimate: TechX Corp Infrastructure

> **Status:** Planning estimate (configuration-based), not a live AWS invoice.  
> **Account / Region:** `493499579600` / `us-east-1`  
> **Last updated:** 2026-07-10  
> **Scope:** Full-component platform on EKS as defined by current Terraform (`techx-corp-infra`) and Helm chart (`techx-corp-chart` / `tf2-corp-chart`).

This document estimates **monthly AWS spend** for running the TechX stack with **all major application and observability components enabled**, based on the checked-in environment configs.

For deployment topology and procedures, see [DEPLOYMENT.md](./DEPLOYMENT.md).

---

## 1. Executive summary

| Scenario | Estimated monthly cost (USD) |
|---|---:|
| **One full environment** (dev *or* prod, 24/7, desired 2 nodes) | **~$280–320** |
| **Planning buffer** (scale toward 3–4 nodes, heavier load-gen / NAT) | **~$350–450** |
| **Both environments** (dev + prod, 24/7, full stack each) | **~$560–650** |
| **Both at max node capacity** (4× `t3.large` each) | **~$800–900+** |

**Recommended budget number for a single full environment:** **~$300 / month**.  
**Recommended budget number if both stacks stay up 24/7:** **~$600 / month**.

### Cost composition (one env, mid estimate ~$280)

| Category | Share | Approx. $/mo |
|---|---:|---:|
| EC2 worker nodes (2× `t3.large`) | ~43% | ~$121 |
| EKS control plane | ~26% | ~$73 |
| NAT Gateway (+ IPv4 + light data) | ~14% | ~$40 |
| Application Load Balancer | ~8% | ~$22 |
| Storage, ECR, Secrets Manager, CloudWatch, transfer | ~9% | ~$25 |

Platform fixed costs (EKS + NAT + ALB) are large relative to this demo-sized workload: roughly **$128 / month** before significant application traffic.

---

## 2. Scope and assumptions

### 2.1 In scope (AWS bill)

- EKS control plane and managed node groups
- VPC networking: NAT Gateway, public IPv4 on NAT EIP, cross-AZ transfer (estimated)
- Storefront **internal ALB** (AWS Load Balancer Controller + chart Ingress) + optional CloudFront VPC origin
- Optional **AWS Client VPN** for private admin access to that ALB (off by default; association + connection hours)
- EBS for node root volumes and application PVCs
- ECR nested repositories and image storage
- AWS Secrets Manager secret *metadata* (SEC-05 shells)
- External Secrets Operator and ALB Controller **compute** (runs on the same nodes; no separate service fee)
- Optional Argo CD (dev enabled) — runs on cluster nodes
- CloudWatch and data-transfer allowances (rough)

### 2.2 Out of scope

- GitHub Actions **runner minutes** (GitHub billing, not AWS)
- Human / SaaS tools (PagerDuty, Datadog, etc.)
- Savings Plans, Reserved Instances, or **live** Spot discounts on Karpenter elastic nodes (MNG floor is On-Demand; estimate treats worker list price as on-demand)
- Multi-region disaster recovery
- Production traffic growth beyond load-generator + light demo use
- LLM **external** model APIs (if any are added later); in-cluster `llm` service compute is covered only as a pod on the nodes

### 2.3 Pricing basis

| Input | Value used |
|---|---|
| Month length | **730 hours** |
| Region | **us-east-1** |
| EKS standard support | **$0.10 / cluster-hour** (~$73/mo) |
| EC2 `t3.large` Linux on-demand | **~$0.0832 / hour** (~$60.74/instance-mo) |
| NAT Gateway | **$0.045 / hour** + **$0.045 / GB** processed |
| Public IPv4 (in-use) | **~$0.005 / hour** |
| ALB | **$0.0225 / hour** + **$0.008 / LCU-hour** |
| EBS gp3 | **~$0.08 / GB-month** (node volumes, assumed) |
| EBS gp2 | **~$0.10 / GB-month** (chart default `storageClassName: gp2`) |
| Secrets Manager | **~$0.40 / secret / month** |
| ECR storage | **~$0.10 / GB-month** |

Rates change over time. Re-validate against [AWS Pricing Calculator](https://calculator.aws/) and Cost Explorer before formal budgeting.

### 2.4 Source of truth in this monorepo

| Layer | Path / config |
|---|---|
| Dev stack | `environments/development/terraform.tfvars` |
| Prod stack | `environments/production/terraform.tfvars` |
| VPC / NAT | `modules/vpc` |
| EKS / ALB IAM | `modules/eks` |
| ECR catalog | `modules/ecr` (default service list) |
| Secrets shells | `modules/secrets-manager` |
| Argo CD | `modules/argocd` (`argocd_enabled`) |
| App + observability | `techx-corp-chart/values.yaml` + `values-public-alb.yaml` + `values-dev.yaml` / `values-prod.yaml` |

---

## 3. What “full components” means

### 3.1 Infrastructure (each environment)

Both **development** and **production** currently use the same compute shape:

| Resource | Development | Production |
|---|---|---|
| Project / VPC prefix | `techx-dev` | `techx` |
| VPC CIDR | `10.1.0.0/16` | `10.0.0.0/16` |
| Public subnets | 2 AZs | 2 AZs |
| Private subnets | 2 AZs | 2 AZs |
| NAT Gateways | **1** (`nat-1a`, shared) | **1** (`nat-1a`, shared) |
| EKS cluster | `techx-dev` | `techx-tf2` |
| Kubernetes version | `1.36` (tfvars) | `1.32` (tfvars) |
| Node groups (system MNG) | `general-1a`, `general-1b` | `general-1a`, `general-1b` |
| Instance type (MNG) | `t3.large` **on-demand** (critical floor) | `t3.large` on-demand |
| Desired / min / max per AZ (MNG) | **1 / 1 / 3** | **1 / 1 / 2** |
| Cluster desired nodes (MNG floor) | **2** | **2** |
| Cluster max nodes (MNG only) | **6** | **4** |
| Karpenter | **Spot preferred** + OD fallback (spot-tolerant apps); CPU limit 32 | On-Demand NodePool when install enabled; CPU limit 64 |
| Node disk | 30 GB | 30 GB |
| ECR project | `techx-dev-corp/*` (keep last **5** runtime + **1** `buildcache`) | `techx-corp/*` (keep last **20** runtime + **1** `buildcache`) |
| Argo CD (`argocd_enabled`) | **true** | **false** |
| Storefront internal ALB | Yes (Helm overlay) | Yes (Helm overlay) |
| Path blocking | CloudFront Function (optional; off default in dev) | CloudFront Function (on when CF enabled) |
| Client VPN (admin path) | Optional; **off** by default | Optional; **off** by default (association cost) |
| Secrets Manager shells | 5 per env (prefix differs) | 5 per env |

**Node capacity (desired):** 2 × `t3.large` = **4 vCPU / 16 GiB** raw (before kubelet / system reservation).

**Pod density (not extra instances):** VPC CNI **prefix delegation** + kubelet **maxPods=110** on MNG and Karpenter nodes (default ENI mode is maxPods≈35 on `t3.large`). This raises how many pods fit **per node** so DaemonSets (e.g. OTEL agent) and system controllers do not fail with `Too many pods`. It does **not** increase the MNG desired count or NodePool CPU/memory limits. Prefix mode uses `/28` IP blocks on private `/24` subnets — fine at demo scale; watch available IPs if node count grows.

### 3.2 Application components (Helm)

All of the following are **`enabled: true`** in chart `values.yaml` under `components:`:

| Component | Notes |
|---|---|
| accounting, ad, cart, checkout, currency | Microservices |
| email, fraud-detection, payment, quote, shipping | Microservices |
| product-catalog, product-reviews, recommendation | Microservices |
| frontend, frontend-proxy, image-provider | Storefront path |
| flagd, llm | Feature flags + LLM service |
| load-generator | **Continuous synthetic traffic** (cost and capacity driver) |
| kafka | Stateful, PVC **5Gi** |
| postgresql | Stateful, PVC **5Gi** |
| valkey-cart | Stateful, PVC **2Gi** |

Subcharts / platform add-ons (also enabled by default):

| Component | Mode / notes |
|---|---|
| opentelemetry-collector | DaemonSet (1 pod per node) |
| jaeger | In-memory traces |
| prometheus | Server only; many subcomponents disabled |
| grafana | Admin via ESO secret |
| opensearch | Single node; **500m** CPU / **~1100Mi** memory request (Guaranteed); persistence off |
| metrics-server | Required for HPA |

**Autoscaling (HPA):**

| Service | minReplicas | maxReplicas |
|---|---:|---:|
| frontend | **2** | 6 |
| checkout | **2** | 6 |

Default replicas for other components: **1**.

### 3.3 Approximate Kubernetes resource requests (steady state)

Including HPA minimums (frontend ×2, checkout ×2) and OTel Collector ×2 (DaemonSet on 2 nodes):

| Metric | Approximate total |
|---|---|
| CPU requests | **~2.4 cores** |
| Memory requests | **~5.4 GiB** |

This is **application + chart observability only**. It does **not** include:

- `kube-system` (CoreDNS, kube-proxy, aws-node, EBS CSI, Load Balancer Controller, …)
- External Secrets Operator
- Argo CD (dev)
- EmptyDir / JVM / page cache beyond requests

**Implication:** Desired **2× t3.large** system MNG is intentionally tight for a full demo. Memory-heavy pods (OpenSearch **1100Mi**, Kafka **700Mi**, load-generator **500Mi**) can cause Pending pods; **Karpenter** then adds workload nodes (Spot-first in dev) within NodePool limits — see `docs/karpenter.md`. **Pod-count** pressure (not CPU/memory) is mitigated by prefix delegation + maxPods; Karpenter min instance CPU ≥ 2 avoids 1-vCPU nodes that only allow ~8 pods.

---

## 4. Monthly cost model — one environment

### 4.1 Mid estimate (recommended planning baseline)

Assumptions:

- 24/7 operation
- Desired **2× t3.large** on-demand
- Public ALB present
- One NAT Gateway
- Light–moderate load-generator traffic (~50 GB NAT processing, ~1 ALB LCU average)
- ~15 GB ECR image storage for that env’s registry prefix
- 5 Secrets Manager secrets
- Rough CloudWatch + data transfer allowance

| Line item | Calculation sketch | Est. $/mo |
|---|---|---:|
| EKS control plane | 0.10 × 730 | **73.00** |
| EC2 2× t3.large | 0.0832 × 730 × 2 | **121.47** |
| Node EBS 2×30 GB gp3 | 60 × 0.08 | **4.80** |
| App PVCs ~12 GB gp2 | 12 × 0.10 | **1.20** |
| NAT Gateway hours | 0.045 × 730 | **32.85** |
| NAT public IPv4 | 0.005 × 730 | **3.65** |
| NAT data ~50 GB | 50 × 0.045 | **2.25** |
| ALB hours | 0.0225 × 730 | **16.43** |
| ALB LCU ~1 | 0.008 × 1 × 730 | **5.84** |
| Secrets Manager ×5 | 5 × 0.40 | **2.00** |
| ECR storage ~15 GB | 15 × 0.10 | **1.50** |
| CloudWatch / misc logs | allowance | **5.00** |
| Data transfer (egress + cross-AZ) | rough | **11.80** |
| **Total (mid)** | | **~$282** |

**Planning range for one full environment: ~$280–320 / month.**

### 4.2 Scenario ranges (one environment)

| Scenario | Est. $/mo | Drivers |
|---|---:|---|
| **Low** | **~$250–270** | Quiet traffic; less NAT/ALB/transfer; load-gen idle or disabled |
| **Mid (baseline)** | **~$280–320** | Desired 2 nodes + load-gen + public ALB |
| **High / stressed** | **~$380–450** | 3 nodes common; heavy NAT (e.g. 200 GB); higher ALB LCU; more logs |
| **At max nodes (4× t3.large)** | **~$400–430** floor for compute+platform | `max_size=2` per AZ fully used |

### 4.3 EC2 sensitivity (on-demand, us-east-1)

| Running nodes | Approx. EC2 only | Approx. mid total (hold other mid costs) |
|---:|---:|---:|
| 2 (desired) | ~$121 | ~$280 |
| 3 | ~$182 | ~$345 |
| 4 (max) | ~$243 | ~$410 |

---

## 5. Both environments (dev + prod)

Dev and prod are **independent stacks** (separate VPC, EKS, NAT, ALB, node groups, ECR prefixes, Secrets Manager names). Costs largely **double** when both run full stack 24/7.

| Stack | Est. $/mo (mid) | Notes |
|---|---:|---|
| Development only | **~$280–320** | Argo CD on (small pod overhead, not a separate AWS SKU) |
| Production only | **~$280–320** | Argo CD off in tfvars; slightly lower in-cluster load |
| **Dev + prod** | **~$560–650** | Planning number **~$600** |
| Shared bootstrap (S3 state, KMS, OIDC) | **&lt; ~$5** | Negligible vs EKS/EC2 |

Prod ECR keeps more runtime image history (`keep_last_n_images = 20` vs dev `5`; both keep **1** `buildcache`), so **ECR storage** may be higher on prod over time (still small vs compute).

---

## 6. Variable cost drivers

These items move month-to-month more than the EKS control-plane fee.

| Driver | Effect | Config / behavior |
|---|---|---|
| **Node count** | Dominant variable | MNG `desired_size` + **Karpenter** NodePools (Pending pods / HPA) |
| **Karpenter Spot vs OD** | Dev often cheaper; interruptions | `karpenter_spot_preferred`; see `docs/karpenter.md` |
| **Load-generator** | CPU, ALB LCU, NAT, cross-AZ | `components.load-generator.enabled` |
| **NAT data processing** | $0.045/GB | Image pulls, package updates, external APIs |
| **ALB LCU** | Connections, bytes, rules | Storefront + load-gen |
| **Cross-AZ traffic** | Pod-to-pod across AZs | Two node groups in two AZs by design |
| **t3 Unlimited credits** | Extra if sustained CPU &gt; baseline | Load-gen + OpenSearch under stress |
| **ECR growth** | Storage + optional scan | Lifecycle policies limit history |
| **CloudWatch logs** | Ingest + retention | Control-plane logging not enabled by default in modules; still plan for app/controller logs if enabled later |

---

## 7. Cost optimization options

Ordered roughly by impact for this architecture. Trade-offs are intentional — document operational impact before applying.

| Lever | Potential savings | Trade-off |
|---|---|---|
| **Stop / scale-to-zero non-prod** nights & weekends | ~50–70% of **dev** compute | No overnight demos / CI against live cluster |
| **Disable load-generator** when not demoing | Lower CPU, ALB, NAT | No continuous synthetic traffic |
| **Spot capacity** for dev node groups | ~50–70% of EC2 for Spot share | Interruptions; not for strict prod SLO |
| **Single larger node or single AZ (dev only)** | Less cross-AZ; simpler | Weaker AZ failure tolerance; EBS stickiness |
| **Share one cluster, two namespaces** | Save **~$73 EKS + ~$33 NAT** (~$100+/mo) for second env | Blast radius / multi-tenant complexity |
| **Second NAT for HA** | — (cost **up** ~$33+/mo) | Higher resilience; **not** current config |
| **gp3 for app PVCs** | Small storage % | Change default `storageClassName` |
| **Savings Plans / RIs** (prod steady state) | 20–40% EC2 | Commitment; wrong size locks waste |
| **Right-size after metrics** | Avoid 4th node | Needs Metrics Server + HPA tuning already present |

**Already cost-conscious choices in repo:**

- Single NAT per environment (not one NAT per AZ)
- Small on-demand node footprint (2× `t3.large` desired)
- OpenSearch / Prometheus persistence often off or minimal
- Dev ECR lifecycle keep-last **5** runtime images + **1** `buildcache` per repo
- Prod Argo CD install gated off until ready

---

## 8. Capacity and scheduling risk

Full stack resource requests (~2.4 CPU / ~5.4 GiB) plus system pods leave **little headroom** on 2× `t3.large`.

| Risk | Symptom | Cost impact |
|---|---|---|
| Memory pressure | Pending OpenSearch / Kafka / app pods | Scale to 3–4 nodes (+$60–$120/mo) |
| HPA scale-out | frontend/checkout &gt; minReplicas | Extra pod CPU/memory → may need more nodes |
| Image pull storms | Many pods restarting | NAT data processing spikes |
| t3 credit exhaustion | Throttling or Unlimited charges | Latency + possible credit $ |

**Operational check before budgeting only the $280 number:**

```bash
# After deploy: node allocatable vs requests
kubectl top nodes
kubectl describe nodes | findstr /i "Allocatable Allocated"
kubectl get pods -A --field-selector=status.phase=Pending
```

If Pending pods or sustained high memory are normal, plan for the **$350–450** band (one env) or **$700–900** (both envs).

---

## 9. How to refresh this estimate

1. **Config drift:** Re-read `environments/*/terraform.tfvars` (instance types, desired/max sizes, NAT count) and chart `values*.yaml` (enabled components, HPA, PVCs, ALB).
2. **Price drift:** Re-check AWS public pricing or Pricing Calculator for `us-east-1`.
3. **Actuals:** Use AWS Cost Explorer filtered by tags:
   - `Project = techx-platform`
   - `Environment = development | production`
4. **Optional:** Tag-based monthly report after 14–30 days of steady full-stack runtime for a calibration factor (actual / estimate).

### Suggested Cost Explorer dimensions

| Dimension | Example |
|---|---|
| Service | AmazonEKS, AmazonEC2, EC2-Other (NAT/EIP), Elastic Load Balancing, AmazonECR, Secrets Manager, AmazonVPC |
| Tag | `Environment`, `Project` |
| Linked account | `493499579600` (if multi-account later) |

---

## 10. Worked example — annualized

| Plan | Monthly mid | Annualized (×12) |
|---|---:|---:|
| One full env | ~$300 | **~$3,600** |
| Dev + prod both full | ~$600 | **~$7,200** |
| Both envs, often at 4 nodes | ~$850 | **~$10,200** |

These figures exclude GitHub CI and any non-AWS tools.

---

## 11. Related documents

| Document | Purpose |
|---|---|
| [DEPLOYMENT.md](./DEPLOYMENT.md) | End-to-end infra + ECR + env constants |
| [USAGE_GUIDE.md](./USAGE_GUIDE.md) | Terraform remote state / S3 bootstrap |
| Chart `docs/DEPLOYMENT.md` | Helm / GitOps / public ALB application deploy |
| Chart `values.yaml` | Component enablement, resources, PVCs, HPA |
| Chart `values-public-alb.yaml` | Internal storefront ALB (CloudFront VPC origin target) |
| [client-vpn.md](./client-vpn.md) | Optional Client VPN for private admin paths (same internal ALB) |

**Client VPN (when enabled):** ~$0.10/hour per associated subnet + ~$0.05/hour per active connection + data. Default **one** subnet association. Leave disabled when unused.

---

## 12. Changelog

| Date | Change |
|---|---|
| 2026-07-10 | Initial estimate for full-component single env (~$280–320) and dual env (~$560–650) based on current tfvars and chart defaults. |
| 2026-07-13 | Document optional Client VPN cost (off by default; association hours). |

---

## Disclaimer

This is an **engineering planning document**. It is not a quote from AWS. Taxes, enterprise discounts, Free Tier remaining balance, Support plan fees, and unexpected data-transfer patterns can change the invoice. Prefer **Cost Explorer actuals** for financial reporting once the stacks have run under representative load.
