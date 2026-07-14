# CPU Architecture: amd64 vs arm64 (Graviton)

This document explains the differences between **amd64 (x86_64)** and **arm64 (Graviton)** for TechX EKS, how this workspace is wired today, and a **bidirectional migration plan** for switching node architectures.

It is the architecture counterpart to:

* [`workload-placement.md`](./workload-placement.md) — critical MNG vs Karpenter placement
* [`karpenter.md`](./karpenter.md) — capacity provisioning
* [`DEPLOYMENT.md`](./DEPLOYMENT.md) — end-to-end deploy runbook
* `techx-corp-platform/docs/CICD.md` — multi-arch image bake

---

## 1. Glossary

| Term | Meaning in this stack |
|------|------------------------|
| **amd64** | Kubernetes / Go name for 64-bit x86 (`x86_64`). EC2 families such as `t3`, `m5`, `c5`, `m7i`. |
| **arm64** | Kubernetes name for 64-bit ARM (`aarch64`). EC2 **Graviton** families such as `t4g`, `m7g`, `c7g`, `r7g`. |
| **Node architecture** | CPU ISA of the EC2 instance and its EKS-optimized AMI. Reported on nodes as `kubernetes.io/arch`. |
| **Image architecture** | CPU ISA of container image layers. Multi-arch tags use a **manifest list** with both `linux/amd64` and `linux/arm64`. |
| **Hybrid cluster** | Some nodes amd64 and some arm64 at once. Works only when every scheduled image can pull the correct arch. |

**Do not use these as `kubernetes.io/arch` values:** `x86_64`, `aarch64`, `arm`, `x64`. Use only `amd64` or `arm64`.

---

## 2. Why architecture matters

Kubernetes schedules pods onto nodes. The **container binary must match the node ISA**.

```
Pod pulls image tag ──► registry returns layer for node arch
                              │
                              ├─ match   → container starts
                              └─ mismatch → CrashLoopBackOff
                                            "exec format error"
```

| Component | Must match node arch? |
|-----------|------------------------|
| First-party app images (ECR) | **Yes** (or multi-arch manifest) |
| Third-party images (postgres, flagd, OTEL, charts) | **Yes** |
| EKS add-on DaemonSets (vpc-cni, kube-proxy, ebs-csi-node) | **Yes** (AWS publishes multi-arch) |
| Node AMI (`ami_type` / Karpenter `ami_alias`) | **Yes** — must match instance family |
| Terraform / Helm chart YAML | No (control plane is arch-agnostic) |
| Application source language (Go/Java/Python) | No at source level; **compiled/native layers** must be built per arch |

Architecture is **independent** of:

* `workload-class=critical` vs `spot-tolerant` (placement)
* Spot vs On-Demand (capacity type)
* Instance **size** (`medium` vs `large`) — size is CPU/RAM capacity, not ISA

---

## 3. Side-by-side comparison

### 3.1 CPU / platform

| Dimension | amd64 (x86_64) | arm64 (Graviton) |
|-----------|----------------|------------------|
| Kubernetes label | `kubernetes.io/arch=amd64` | `kubernetes.io/arch=arm64` |
| Typical EC2 (this repo) | `t3.medium`, `t3.large` | `t4g.medium` (MNG); Karpenter `c`/`m`/`r` Graviton (e.g. `m7g`, `c7g`) |
| EKS MNG AMI type | `AL2023_x86_64_STANDARD` | `AL2023_ARM_64_STANDARD` |
| Karpenter AMI alias | `al2023@latest` (resolves x86 when arch=amd64) | `al2023@latest` (resolves ARM when arch=arm64) |
| Docker platform | `linux/amd64` | `linux/arm64` |
| Cost (same size class) | Baseline | Often **lower** $/vCPU for Graviton |
| Ecosystem | Widest binary support | Excellent for mainstream images; rare legacy amd64-only binaries fail |

### 3.2 Instance + AMI pairing (must stay consistent)

| Instance family | Correct `ami_type` (managed node group) |
|-----------------|----------------------------------------|
| `t3`, `m5`, `c5`, `m7i`, … | `AL2023_x86_64_STANDARD` |
| `t4g`, `m7g`, `c7g`, `r7g`, … | `AL2023_ARM_64_STANDARD` |

**Invalid:** `instance_types = ["t4g.medium"]` with `ami_type = "AL2023_x86_64_STANDARD"` (or the reverse). EKS rejects or fails node bootstrap.

### 3.3 Capacity is not architecture

| Instance | vCPU | Memory | Notes in this stack |
|----------|------|--------|---------------------|
| `t3.medium` / `t4g.medium` | 2 | 4 GiB | Same size class; critical floor can be **tight** (OpenSearch, Kafka, load-generator, observability) |
| `t3.large` / `t4g.large` | 2 | 8 GiB | More RAM headroom for critical packing |

Switching `t3.large` → `t4g.medium` changes **both** architecture **and** memory budget. Treat those as separate decisions.

---

## 4. How this workspace is wired

### 4.1 Config surfaces

| Layer | File / location | Architecture control |
|-------|-----------------|----------------------|
| **MNG instance + AMI** | `environments/{development,production}/terraform.tfvars` → `node_groups.*.instance_types` + `ami_type` | Per node group |
| **Karpenter node arch** | `modules/karpenter/main.tf` → `kubernetes.io/arch` requirement | **Shared module default** (affects every env that creates NodePools) |
| **Karpenter AMI** | `modules/karpenter` → `ami_alias` default `al2023@latest` | Follows instance arch from requirements |
| **Karpenter instance families** | `instance_categories` default `["t"]` | Burstable T-family only; with `arch=arm64` → primarily `t4g.*` (not Graviton `c`/`m`/`r`) |
| **App images** | `techx-corp-platform/docker-bake.hcl` | `platforms = ["linux/amd64", "linux/arm64"]` for release group |
| **Pod placement** | `techx-corp-chart` `schedulingRules` | Arch-agnostic (`workload-class` only) |

### 4.2 Current environment posture (document when changing)

| Environment | Managed node groups (system) | Karpenter NodePool arch | Notes |
|-------------|------------------------------|-------------------------|--------|
| **development** | `t4g.medium` + `AL2023_ARM_64_STANDARD` | `arm64` (module) | Full ARM path when NodePools are enabled |
| **production** | `t3.medium` / `t3.large` + `AL2023_x86_64_STANDARD` | Module currently requires `arm64` when NodePools are created | Confirm before enabling `karpenter_create_node_resources` on prod |

> **Ops note:** Karpenter architecture is defined in the shared module, not yet as a per-env variable. Changing `values = ["arm64"]` or `["amd64"]` affects every environment that installs NodePools from that module revision. Prefer parameterizing (e.g. `var.node_architecture`) before mixed long-term postures.

### 4.3 Image contract (platform)

CI / bake publishes **multi-arch** release images:

```hcl
# techx-corp-platform/docker-bake.hcl (concept)
platforms = ["linux/amd64", "linux/arm64"]
```

| Requirement | Detail |
|-------------|--------|
| Deployable tags | Multi-arch manifest lists for both platforms |
| Not deployable | `:buildcache` tags (cache only) |
| Failure mode if wrong | Single-arch tag on wrong node → `exec format error` |

Services with explicit multi-arch build support include TARGETARCH-aware .NET (`cart`, `accounting`) and arm64 cross-compile for Rust (`shipping`). Other services rely on buildx multi-platform builds.

### 4.4 Workloads that always need a matching image on the node

**Critical MNG** (must work on whatever arch MNG uses):

* System: CoreDNS, EBS CSI controller (pinned), metrics-server, Argo CD, ESO, Karpenter controller
* Data / edge: `postgresql`, `kafka`, `valkey-cart`, `opensearch`, `frontend-proxy`, `flagd`
* Observability: Prometheus server, Grafana, Jaeger
* Optional pin: `load-generator` (Playwright Chromium — higher ARM risk; validate after switch)

**Karpenter nodes:** stateless `spot-tolerant` app Deployments + universal DaemonSets (vpc-cni, kube-proxy, ebs-csi-node, OTEL agent).

---

## 5. Choosing an architecture

| Prefer **arm64 (Graviton)** when | Prefer **amd64** when |
|----------------------------------|------------------------|
| Cost efficiency on general Linux workloads | You depend on a known amd64-only binary/image |
| Multi-arch ECR tags already published and verified | Emergency rollback to last-known-good x86 MNGs |
| New or greenfield env (e.g. dev) | Third-party vendor only supports amd64 |
| Willing to smoke-test native/browser tooling (e.g. Playwright) | Temporary dual-run during migration |

**Recommended default for this platform:** keep **multi-arch images always**, then pick node arch per environment for cost vs risk. Do not ship single-arch-only tags if you may switch nodes.

---

## 6. Migration principles

1. **Images before nodes.** Never move nodes to a new arch until the image tag in use is multi-arch (or native to the target arch).
2. **Pair instance type and AMI.** Always change `instance_types` and `ami_type` together for MNGs.
3. **Align Karpenter arch with intended capacity.** NodePool `kubernetes.io/arch` must match the instances you expect.
4. **Prefer create-new + drain over in-place rewrite** when possible: new node group (or temporary dual-arch capacity) → cordon/drain old → delete old.
5. **One environment at a time.** Complete dev acceptance before production.
6. **Capacity is a separate gate.** Shrinking `large` → `medium` can fail placement even if arch is correct.
7. **Freeze disruption during cutover.** Karpenter disruption budgets / maintenance windows as needed (see `workload-placement.md`).

---

## 7. Migration plan: amd64 → arm64

Example: production-style `t3.*` + `AL2023_x86_64_STANDARD` → Graviton `t4g.*` + `AL2023_ARM_64_STANDARD`, and Karpenter `amd64` → `arm64`.

### Phase 0 — Preconditions

| Step | Action | Pass criteria |
|------|--------|---------------|
| 0.1 | Inventory current node arch | `kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type` |
| 0.2 | Confirm deploy image tag is multi-arch | `docker buildx imagetools inspect $ECR_REPO/<service>:$TAG` shows `linux/amd64` **and** `linux/arm64` for critical services (at least `frontend-proxy`, `checkout`, `opensearch`, `kafka`) |
| 0.3 | If tag is amd64-only | Re-run platform multi-arch bake/push; promote chart tag only after full catalog verify |
| 0.4 | Capacity plan | Compare target instance RAM/CPU vs critical requests (OpenSearch ~1100Mi, Kafka ~700Mi, load-gen ~500Mi + system) |
| 0.5 | Change docs | Update this table in §4.2 and env tfvars in the same PR as the switch |

### Phase 1 — Configuration change (Terraform / module)

**Managed node groups** (`terraform.tfvars`):

```hcl
instance_types = ["t4g.medium"]          # or t4g.large if RAM required
ami_type       = "AL2023_ARM_64_STANDARD"
```

**Karpenter** (`modules/karpenter/main.tf` or preferred future `var.node_architecture`):

```hcl
key      = "kubernetes.io/arch"
operator = "In"
values   = ["arm64"]
```

Leave `ami_alias = "al2023@latest"` unless you pin a specific AMI.

Optional: temporarily allow **both** arches during dual-run:

```hcl
values = ["amd64", "arm64"]
```

Only do this if multi-arch images are verified; remove dual allow-list after cutover to avoid surprise instance families.

### Phase 2 — Safe roll strategy (recommended)

```
┌─────────────────┐     create      ┌─────────────────┐
│ Old amd64 MNG   │ ──────────────► │ New arm64 MNG   │
│ (still serving) │                 │ (empty / Ready) │
└────────┬────────┘                 └────────┬────────┘
         │ cordon + drain                     │
         │ pods reschedule ──────────────────►│
         ▼                                    ▼
   delete old NG                         target state
```

| Step | Action |
|------|--------|
| 2.1 | Add new arm64 node groups **or** replace instance/AMI on existing NGs knowing EKS will roll nodes |
| 2.2 | Wait until new nodes `Ready` with `kubernetes.io/arch=arm64` |
| 2.3 | Apply Karpenter arch change; recycle existing Karpenter nodes (delete NodeClaims or cordon/drain) so new launches are arm64 |
| 2.4 | Cordon old amd64 nodes: `kubectl cordon <node>` |
| 2.5 | Drain: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data` (respect PDBs; drain one AZ at a time if possible) |
| 2.6 | Confirm critical pods Running on arm64; remove old node groups from Terraform and apply |

> EKS managed node group updates that change `instance_types` / `ami_type` often **force node replacement**. Prefer an explicit dual-run when the critical floor is thin (`desired_size=1` per AZ).

### Phase 3 — Validation

| Check | Command / method | Expected |
|-------|------------------|----------|
| Node arch | `kubectl get nodes -L kubernetes.io/arch` | Target nodes `arm64` |
| No Pending (arch) | `kubectl get pods -A \| findstr Pending` (or `grep`) | No arch-related Pending |
| No exec format | `kubectl get pods -A \| findstr CrashLoop` + `kubectl logs` / `describe` | No `exec format error` |
| Critical services | Hit storefront, login paths, Kafka consumers, OpenSearch, Grafana | Healthy |
| Karpenter | Pending stateless pod → new NodeClaim | Instance is Graviton; arch=arm64 |
| DaemonSets | vpc-cni, kube-proxy, ebs-csi-node, otel agent | Ready on every node |
| Load-generator (if enabled) | Locust UI / logs | Chromium/Playwright works on arm64 |

### Phase 4 — Close-out

* Remove temporary dual-arch Karpenter allow-list if used  
* Update §4.2, `workload-placement.md` instance examples, COST notes if needed  
* Record change under `docs/changes/YYYY-MM-DD-….md`  
* Keep multi-arch bake enabled (do not drop amd64 from bake unless org standardizes on arm-only images)

---

## 8. Migration plan: arm64 → amd64 (rollback or reverse)

Use when rolling back Graviton issues or standardizing on x86.

### Phase 0 — Preconditions

| Step | Action | Pass criteria |
|------|--------|---------------|
| 0.1 | Confirm image tag includes `linux/amd64` | `imagetools inspect` |
| 0.2 | Choose instance sizes with **enough RAM** (do not silently drop `large` → `medium` during emergency rollback unless capacity is reviewed) | Requests fit allocatable |
| 0.3 | Snapshot / note current arm64 node names for drain order | Inventory complete |

### Phase 1 — Configuration

**Managed node groups:**

```hcl
instance_types = ["t3.medium"]   # or t3.large
ami_type       = "AL2023_x86_64_STANDARD"
```

**Karpenter:**

```hcl
values = ["amd64"]
```

### Phase 2 — Roll

Same dual-run pattern as §7 Phase 2, inverted:

1. Ensure amd64 capacity is Ready  
2. Point Karpenter at `amd64`; recycle Karpenter nodes  
3. Cordon/drain arm64 nodes  
4. Remove arm64 node groups  

### Phase 3 — Validation

Mirror §7 Phase 3 with expected arch `amd64` and x86 instance types (`t3`, `m5`, `m7i`, etc.).

---

## 9. Hybrid operation (temporary)

| Mode | When useful | Rules |
|------|-------------|--------|
| Dual-arch NodePool `["amd64","arm64"]` | Soft migration / mixed Spot supply | Multi-arch images **required** for all pods that can land on either |
| ARM MNG + amd64 Karpenter (or reverse) | Staged migration | Critical-only images must match **MNG** arch; stateless must match **Karpenter** arch — multi-arch still simplest |
| Long-term hybrid | Usually avoid | Harder capacity planning; easy to mis-schedule single-arch images |

**Recommendation:** hybrid only for a measured cutover window; end state is single arch per environment.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Node group create/update fails on AMI/instance | `ami_type` does not match instance family | Align per §3.2 |
| Pod `CrashLoopBackOff`, events mention `exec format error` | Image layer wrong arch / single-arch tag | Rebuild multi-arch; roll tag |
| ImagePullBackOff only on new arch nodes | Manifest lacks that platform | Bake both platforms; re-push |
| Karpenter never launches / wrong family | Arch requirement vs instance categories | `arm64` + categories `t` → primarily `t4g.*`; restore `c,m,r` if broader families needed |
| Pending on critical MNG after switch | Not enough CPU/RAM on medium | Scale size (`t4g.large`) or reduce critical pack / raise `desired_size` via reviewed TF |
| Load-generator fails only on arm64 | Playwright/Chromium platform issue | Disable load-gen temporarily; pin to remaining amd64; or fix image deps |
| DaemonSet not Ready on new nodes | Taints / maxPods / CNI | See `karpenter.md` pod density; not usually arch-specific |

---

## 11. Checklist (copy-ready)

### Switch to arm64

- [ ] Multi-arch (or arm64) ECR tag verified for deploy version  
- [ ] MNG `instance_types` are Graviton (`t4g` / etc.)  
- [ ] MNG `ami_type = "AL2023_ARM_64_STANDARD"`  
- [ ] Karpenter `kubernetes.io/arch` includes `arm64`  
- [ ] Capacity review for medium vs large  
- [ ] New nodes Ready with `kubernetes.io/arch=arm64`  
- [ ] Old nodes drained; no critical pods left on wrong arch  
- [ ] Smoke: storefront, data plane, observability, Karpenter scale-out  
- [ ] Docs §4.2 + change record updated  

### Switch to amd64

- [ ] Multi-arch (or amd64) ECR tag verified  
- [ ] MNG `instance_types` are x86 (`t3` / etc.)  
- [ ] MNG `ami_type = "AL2023_x86_64_STANDARD"`  
- [ ] Karpenter `kubernetes.io/arch` includes `amd64`  
- [ ] Capacity review  
- [ ] New nodes Ready with `kubernetes.io/arch=amd64`  
- [ ] Drain old arm64; smoke tests  
- [ ] Docs + change record updated  

---

## 12. Related repository paths

| Path | Role |
|------|------|
| `environments/development/terraform.tfvars` | Dev MNG instance + AMI |
| `environments/production/terraform.tfvars` | Prod MNG instance + AMI |
| `modules/eks/` | Node group resources (`ami_type`, `instance_types`) |
| `modules/karpenter/main.tf` | NodePool arch requirement |
| `modules/karpenter/charts/node-resources/` | EC2NodeClass + NodePool templates |
| `techx-corp-platform/docker-bake.hcl` | Multi-arch release platforms |
| `techx-corp-chart/values.yaml` | Placement (`workload-class`), not arch |

---

## 13. Non-goals

* Changing application business logic for ARM  
* Forcing single-arch-only images as an optimization (not recommended here)  
* Using architecture labels as a substitute for `workload-class` placement  
* Documenting non-Linux / Windows node pools  

---

## 14. Summary

| Topic | Takeaway |
|-------|----------|
| **Difference** | amd64 = x86 nodes/images; arm64 = Graviton; labels, AMI types, and instance families differ |
| **Compatibility** | Platform bake is multi-arch; charts are arch-agnostic; nodes + AMI + Karpenter arch must align |
| **Migration** | Verify images → change MNG + Karpenter together → dual-run/drain → smoke → document |
| **Rollback** | Reverse of forward path; keep multi-arch images so either direction stays possible |

<!-- Change trail: @hungxqt - 2026-07-14 - Align Karpenter family docs with t-category default. -->

