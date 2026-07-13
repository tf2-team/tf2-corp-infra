# Tài liệu Hướng dẫn Triển khai End-to-End (Production Runbook)

> [!NOTE]
> **Vai trò của Repository này (`techx-corp-infra`):**
> Repository này chịu trách nhiệm **Terraform**: bootstrap remote state + **GitHub Actions OIDC + platform ECR push roles + infra Terraform plan/apply roles**, VPC, EKS, **nested ECR** (`techx-prod-corp/*`, `techx-dev-corp/*`), và IAM cho AWS Load Balancer Controller.

---

## 1. Mục tiêu (Objectives)

- Bootstrap S3 remote state (encrypted, lockfile).
- Provision production & development stacks.
- Tạo **đủ ECR repository** theo format image:
  ```text
  [REGISTRY]/[PROJECT]/[SERVICE]:[VERSION]
  ```
- Bootstrap tạo account-level GitHub OIDC provider + IAM roles push image (platform) + Terraform plan/apply roles (infra repo) — OIDC, không access key dài hạn.
- Xuất outputs cho platform CI/CD, infra GitHub secrets, và chart Helm.

## 2. Bản đồ Repository

| Repository | Vai trò |
|---|---|
| **`techx-corp-infra`** | Terraform: bootstrap (state + GHA OIDC/ECR + Terraform plan/apply roles), network, EKS, ECR nested, ALB IAM |
| **`techx-corp-platform`** | Build/push images vào ECR |
| **`techx-corp-chart`** | Helm deploy từ image `REGISTRY/PROJECT/SERVICE:VERSION` |

## 3. Điều kiện tiên quyết

- AWS account `493499579600`, region `us-east-1`
- Terraform `>= 1.10.0` (khuyến nghị `v1.15.7`), AWS provider `~> 5.0`, TLS provider `~> 4.0`
- AWS credentials đủ quyền IAM/ECR/EKS/VPC
- **Không** commit `*.tfstate`, `backend.hcl` thật, `*.tfplan` chứa secret

## 4. Hằng số & cấu hình

### Chung

| Hằng số | Giá trị |
|---|---|
| Account / Region | `493499579600` / `us-east-1` |
| State bucket (sau bootstrap) | `techx-tf-state-493499579600-us-east-1` |
| Image format | `REGISTRY/PROJECT/SERVICE:VERSION` |

### Production (`environments/production`)

| Hằng số | Giá trị |
|---|---|
| `project_name` (infra tags/VPC prefix) | `techx` |
| `ecr_project_name` | `techx-prod-corp` |
| Nested repos | `techx-prod-corp/ad`, `techx-prod-corp/checkout`, … |
| Image base | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp` |
| EKS | `techx-tf2` |
| GHA role (bootstrap) | `techx-gha-platform-prod` |
| GitHub Environment (OIDC sub) | `production` |
| Allowed refs | `refs/heads/main`, `refs/tags/v*` |
| State key | `production/terraform.tfstate` |

### Development (`environments/development`)

| Hằng số | Giá trị |
|---|---|
| `project_name` | `techx-dev` |
| `ecr_project_name` | `techx-dev-corp` |
| Nested repos | `techx-dev-corp/ad`, … |
| Image base | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-dev-corp` |
| EKS | `techx-dev` |
| GHA role (bootstrap) | `techx-gha-platform-dev` |
| GitHub Environment | `development` |
| Allowed refs | `refs/heads/techx-dev-corp` |
| State key | `development/terraform.tfstate` |

### Catalog ECR services (module `modules/ecr`)

Một repo nested cho mỗi service bake (đồng bộ platform compose):

`accounting`, `ad`, `cart`, `checkout`, `currency`, `email`, `fraud-detection`, `frontend`, `frontend-proxy`, `image-provider`, `load-generator`, `payment`, `product-catalog`, `product-reviews`, `quote`, `recommendation`, `shipping`, `flagd-ui`, `kafka`, `llm`, `opensearch`

Ví dụ tên repo AWS:

```text
techx-prod-corp/ad
techx-prod-corp/frontend
techx-dev-corp/checkout
```

Image đầy đủ (sau khi platform push):

```text
493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp/ad:sha-a1b2c3d
```

> **Migration note:** Định dạng monorepo cũ (`techx-corp` một repo, tag `1.0-ad`) đã thay bằng nested. Plan có thể **destroy** repo flat cũ và **create** nhiều repo nested — review plan kỹ.

---

## Phase 1: Bootstrap Remote State + GitHub CI/CD IAM

> [!CAUTION]
> 1. Không commit state cục bộ / `backend.hcl` thật.  
> 2. Production: luôn `plan -out` → review → `apply` artifact.  
> 3. Bootstrap owns the **account-level** GitHub OIDC provider, both platform ECR push roles, and this repo’s Terraform plan/apply roles — apply bootstrap **before** environment stacks (and before platform image push / infra GHA).

### Bước 1: Bootstrap

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply "bootstrap.tfplan"
```

**Review plan** — kỳ vọng tạo (trong số khác):

- S3 state bucket + KMS key
- `aws_iam_openid_connect_provider.github` → `token.actions.githubusercontent.com`
- `module.github_actions_ecr["production"].aws_iam_role.this` → `techx-gha-platform-prod`
- `module.github_actions_ecr["development"].aws_iam_role.this` → `techx-gha-platform-dev`
- `module.github_actions_terraform["development-plan|apply"]` → `GitHubTerraformDevPlanRole` / `GitHubTerraformDevApplyRole`
- `module.github_actions_terraform["production-plan|apply"]` → `GitHubTerraformProdPlanRole` / `GitHubTerraformProdApplyRole`

Sau apply bootstrap, copy secrets cho **infra** GitHub repo:

```bash
terraform -chdir=bootstrap output -json github_actions_terraform_github_secrets
# See docs/SETUP.md for Environments + secret names
```

Tạo `bootstrap/backend.hcl` (không commit):

```hcl
bucket       = "techx-tf-state-493499579600-us-east-1"
key          = "bootstrap/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

Migrate state:

```bash
terraform -chdir=bootstrap init -migrate-state -force-copy -backend-config=backend.hcl
terraform -chdir=bootstrap state list
# Xóa terraform.tfstate local sau khi xác nhận
```

### Bước 2: Production stack

Tạo `environments/production/backend.hcl`:

```hcl
bucket       = "techx-tf-state-493499579600-us-east-1"
key          = "production/terraform.tfstate"
region       = "us-east-1"
encrypt      = true
use_lockfile = true
```

```bash
terraform -chdir=environments/production init -backend-config=backend.hcl
terraform -chdir=environments/production fmt -check
terraform -chdir=environments/production validate
terraform -chdir=environments/production plan -out=prod.tfplan
```

**Review plan** — kỳ vọng tạo (trong số khác):

- `module.ecr.aws_ecr_repository.this["ad"]` → name `techx-prod-corp/ad` (× full catalog)
- VPC / EKS / ALB controller role
- **Không** tạo GitHub OIDC provider hay `techx-gha-platform-*` roles (đã ở bootstrap)

```bash
terraform -chdir=environments/production apply "prod.tfplan"
```

### Bước 3: Development stack

```bash
# backend.hcl key = "development/terraform.tfstate"
terraform -chdir=environments/development init -backend-config=backend.hcl
terraform -chdir=environments/development plan -out=dev.tfplan
# Kỳ vọng: techx-dev-corp/<service>; không tạo GHA OIDC/roles
terraform -chdir=environments/development apply "dev.tfplan"
```

### Bước 4: Outputs cho CI/CD & Helm

```bash
# Bootstrap — GHA OIDC + ECR push roles
terraform -chdir=bootstrap output github_oidc_provider_arn
terraform -chdir=bootstrap output github_actions_ecr_production_role_arn
terraform -chdir=bootstrap output github_actions_ecr_development_role_arn
terraform -chdir=bootstrap output github_actions_allowed_subjects

# Production
terraform -chdir=environments/production output ecr_image_base_url
# 493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-prod-corp

terraform -chdir=environments/production output ecr_service_names
terraform -chdir=environments/production output ecr_repository_names
terraform -chdir=environments/production output aws_load_balancer_controller_role_arn
terraform -chdir=environments/production output -raw aws_load_balancer_controller_helm_command

# Development
terraform -chdir=environments/development output ecr_image_base_url
# .../techx-dev-corp
```

**Gán GitHub Environments** (repo platform):

| GitHub Environment | `AWS_ROLE_ARN` | `IMAGE_NAME` |
|---|---|---|
| `production` | bootstrap `github_actions_ecr_production_role_arn` | output prod `ecr_image_base_url` |
| `development` | bootstrap `github_actions_ecr_development_role_arn` | output dev `ecr_image_base_url` |

Chi tiết workflow: `techx-corp-platform/docs/CICD.md`.

---

## Node groups (multi-AZ)

EKS managed node groups use **one group per AZ** so capacity cannot pile into a single zone (EBS PVCs need a node in the volume’s AZ).

| Env | Groups | Subnets |
|-----|--------|---------|
| development | `techx-dev-general-1a`, `techx-dev-general-1b` | `priv-1a`, `priv-1b` |
| production | `techx-tf2-general-1a`, `techx-tf2-general-1b` | `priv-1a`, `priv-1b` |

`subnet_keys` in `terraform.tfvars` are resolved to subnet IDs in `main.tf` from the VPC module.  
Changing from a single multi-subnet group **destroys** the old NG and creates two new ones — pods reschedule; existing EBS volumes stay in their AZ.

```bash
terraform -chdir=environments/development plan
terraform -chdir=environments/development apply
kubectl get nodes -L topology.kubernetes.io/zone
# expect at least one Ready node in us-east-1a and one in us-east-1b
```

Managed node groups remain the **system/bootstrap** pool. **Workload node autoscaling** is handled by **Karpenter** (see next phase and `docs/karpenter.md`).

### Pod density (VPC CNI prefix delegation + maxPods)

Default ENI secondary-IP mode gives **t3.large maxPods ≈ 35**. A full demo (system add-ons + Argo CD/ESO + app stack + DaemonSets such as `otel-collector-agent`) can hit that ceiling. DaemonSets are **node-pinned** — Karpenter adding a *new* node does not free a slot on an already-full node.

Both environments enable:

| Knob | Where | Value |
|------|--------|-------|
| `ENABLE_PREFIX_DELEGATION` / `WARM_PREFIX_TARGET` | `addons.vpc-cni.configuration_values` | `true` / `1` |
| `max_pods` | each managed node group | `110` (AL2023 NodeConfig via launch template) |
| `karpenter_node_max_pods` | Karpenter EC2NodeClass | `110` |
| `karpenter_min_instance_cpu` | NodePool requirement | `2` (avoids 1-vCPU / ~8-pod instances) |

**Apply order / operator steps:**

1. `terraform apply` (updates vpc-cni, creates launch templates, rolls MNG + Karpenter CRs).
2. Confirm CNI: `kubectl -n kube-system set env daemonset/aws-node --list | findstr PREFIX` → `ENABLE_PREFIX_DELEGATION=true`.
3. Confirm maxPods after node recycle:  
   `kubectl get nodes -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels."node\.kubernetes\.io/instance-type",PODS:.status.allocatable.pods`  
   Replaced nodes should show **110** (not 35 / 8).
4. If an old node still shows 35: cordon/drain that node (or wait for MNG rolling update) so a new instance boots with the launch template.
5. Recycle existing Karpenter nodes the same way (maxPods is set at node join).
6. Confirm DaemonSets: `kubectl -n techx-corp-dev get ds otel-collector-agent` → Desired = Ready.

Private subnets are `/24`; prefix mode uses `/28` blocks. With a small node count and `WARM_PREFIX_TARGET=1`, IP pressure is low — monitor `AvailableIpAddressCount` if node count grows large.

---

## CPU architecture (amd64 / arm64)

Node ISA (x86 vs Graviton), EKS `ami_type` pairing, multi-arch image prerequisites, and migration/rollback between architectures: see [`cpu-architecture.md`](./cpu-architecture.md).

## Phase 1b: Karpenter (node autoscaling)

Karpenter provisions EC2 nodes from Pending pods. Discovery tags (`karpenter.sh/discovery = <cluster>`) are applied to private subnets and the cluster security group by the VPC/EKS modules.

Pinned version: **`1.13.1`** for both `karpenter-crd` and `karpenter` (required for Kubernetes 1.36). Upgrade **CRD before controller**. Do not roll back to 1.3.x while the cluster stays on 1.36.

| Env | Spot preferred | Default install (tfvars) |
|-----|----------------|--------------------------|
| development | **yes** (`stateless-spot` weight 100 + `stateless-on-demand` weight 10) | `install_helm` + `create_node_resources` **true** |
| production | **no** (`stateless-on-demand` only for initial placement) | IAM/SQS only until you flip install flags |

Both NodePools use label + taint `workload-class=spot-tolerant:NoSchedule`. Migration disruption budgets default to `"0"` per pool.

```bash
# Development (full install when cluster API is reachable during apply)
terraform -chdir=environments/development plan
terraform -chdir=environments/development apply

kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass,nodepool
kubectl get nodes -L karpenter.sh/nodepool -L karpenter.sh/capacity-type -L workload-class

terraform -chdir=environments/development output karpenter_bootstrap_note
```

Production: set `karpenter_install_helm = true` and `karpenter_create_node_resources = true` in `environments/production/terraform.tfvars` when ready, then apply. Enable Spot only after production placement acceptance.

Full comparison (CA vs Karpenter vs EKS Auto Mode), verification scale-test, and rollback: **`docs/karpenter.md`**.

---

## Phase 1b-extra: Workload placement (critical MNG vs Karpenter hard placement)

**Critical floor:** `system-1a` / `system-1b` (`workload-class=critical`, On-Demand, `max_size=2` ceiling only — **no** Cluster Autoscaler auto scale-out). Legacy `general-*` remains during dual-run migration.

**Karpenter:** labeled + tainted `workload-class=spot-tolerant:NoSchedule` for classified stateless apps.

| Workload | Placement |
|----------|-----------|
| System (Karpenter controller, CoreDNS, ESO, Argo CD, metrics-server, ALB controller, EBS CSI controller) | `nodeSelector: workload-class=critical` |
| Stateful data + observability + `frontend-proxy` / `flagd` | Chart required critical selector (no Karpenter toleration) |
| Classified stateless apps (`frontend`, catalog, recommendation, load-generator, …) | Hard `spot-tolerant` selector + Karpenter toleration |
| Universal DaemonSets (CNI, kube-proxy, ebs-csi-node, OTel agent) | No workload-class selector; tolerate Karpenter taint |
| Unclassified pods | May still land on MNG (one-way isolation) |

**Apply order:** inventory → Karpenter upgrade → create system MNG (create-only plan) → capacity gate → controller pins / NodePool taints → **then** chart sync → migrate AZ-by-AZ → open disruption budgets → remove legacy.

```bash
kubectl get nodes -L workload-class,role,karpenter.sh/nodepool,karpenter.sh/capacity-type
kubectl get pod -A -o wide
```

Details, capacity gates, canaries, rollback: **`docs/workload-placement.md`**.

---

## Phase 1c: Cluster Autoscaler (optional, off by default)

Default capacity remains **small managed node groups + Karpenter**. Cluster Autoscaler is wired in Terraform but **disabled** in both environments (`cluster_autoscaler_enabled = false`, `cluster_autoscaler_install_helm = false`).

* CA scales **MNG ASGs only** within `min_size`/`max_size` — not Karpenter nodes.
* **Do not** enable CA Helm while Karpenter install/NodePools are active (Terraform `check` enforces mutual exclusion).
* For CA-only mode: disable Karpenter first, then flip CA flags. Full runbook: **`docs/cluster-autoscaler.md`**.

```bash
# Defaults create no CA resources
terraform -chdir=environments/development plan | findstr /i "cluster-autoscaler" || true
terraform -chdir=environments/development output cluster_autoscaler_bootstrap_note
```

---

## Phase 2: Kubeconfig & Load Balancer Controller

Output `aws_load_balancer_controller_helm_command` includes **IRSA role ARN**, **`region`**, and **`vpcId`**.  
Those last two are required so the controller does **not** resolve VPC/region via EC2 IMDS (often blocked for pods when IMDSv2 hop limit is 1 → `context deadline exceeded`).

```bash
aws eks update-kubeconfig --region us-east-1 --name techx-tf2
kubectl get nodes

helm repo add eks https://aws.github.io/eks-charts && helm repo update

# Production (or development)
terraform -chdir=environments/production output -raw aws_load_balancer_controller_helm_command
# Paste/run the printed helm upgrade --install (includes region + vpcId + IRSA)

# Equivalent shape (values filled by Terraform output):
# helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
#   -n kube-system \
#   --set clusterName=<cluster> \
#   --set region=us-east-1 \
#   --set vpcId=vpc-xxxxxxxx \
#   --set serviceAccount.create=true \
#   --set serviceAccount.name=aws-load-balancer-controller \
#   --set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<role-arn>

kubectl get deployment -n kube-system aws-load-balancer-controller
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=120s
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
# Expect version info; must NOT see: failed to get VPC ID / ec2imds GetMetadata deadline exceeded
```

---

## Phase 2a: Secrets Manager + External Secrets Operator (SEC-05)

Terraform creates **ASM secret shells** (name/ARN/tags only) and **ESO IRSA**. Secret *values* are **not** in Terraform state.

```bash
terraform -chdir=environments/production apply   # or development

terraform -chdir=environments/production output secrets_manager_secret_names
terraform -chdir=environments/production output external_secrets_role_arn
terraform -chdir=environments/production output -raw external_secrets_helm_command
terraform -chdir=environments/production output -raw external_secrets_cluster_secret_store_manifest
terraform -chdir=environments/production output -raw external_secrets_bootstrap_note
```

**Bootstrap values** (currently live credentials — first cutover does not rotate DB passwords).

Always use the full extension (`.ps1` / `.cmd` / `.sh`). Do not run `.\scripts\bootstrap-asm-secrets` bare — that can pick the wrong file or break under PowerShell.

**PowerShell (recommended on Windows):**

```powershell
cd techx-corp-infra
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/production us-east-1
# dev:
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1
```

**Windows CMD:**

```cmd
cd techx-corp-infra
scripts\bootstrap-asm-secrets.cmd techx-corp/production us-east-1
REM dev:
scripts\bootstrap-asm-secrets.cmd techx-corp/development us-east-1
```

**Bash / Git Bash / WSL:**

```bash
./scripts/bootstrap-asm-secrets.sh techx-corp/production us-east-1
# dev: ./scripts/bootstrap-asm-secrets.sh techx-corp/development us-east-1
```

Optional overrides (same env var names on all shells), e.g. PowerShell:

```powershell
$env:PG_APP_PASSWORD = "otelp"
.\scripts\bootstrap-asm-secrets.ps1 techx-corp/development us-east-1
```

### Install ESO (manual Helm — default)

Prefer Terraform output so chart version + IRSA role ARN stay in sync:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Print + run (do not interrupt --wait; leave the shell open until STATUS=deployed)
terraform -chdir=environments/development output -raw external_secrets_helm_command
# Or production:
# terraform -chdir=environments/production output -raw external_secrets_helm_command
```

Equivalent shape (values filled by TF output):

```bash
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --version 0.14.4 \
  --set installCRDs=true \
  --set serviceAccount.name=external-secrets \
  --set serviceAccount.annotations.eks\.amazonaws\.com/role-arn=<external_secrets_role_arn> \
  --wait --timeout 10m
```

Verify:

```bash
helm status external-secrets -n external-secrets
# expect STATUS: deployed  (not pending-install / pending-upgrade)

kubectl -n external-secrets get pods
# external-secrets, cert-controller, webhook all Ready 1/1

kubectl get sa external-secrets -n external-secrets -o yaml
# must include: eks.amazonaws.com/role-arn: arn:aws:iam::...:role/...-external-secrets
```

Then ClusterSecretStore + secrets chart + app (see chart runbook):

```bash
terraform -chdir=environments/development output -raw external_secrets_cluster_secret_store_manifest | kubectl apply -f -
kubectl get clustersecretstore aws-secretsmanager

# secrets-chart → wait Ready → app chart
# techx-corp-chart/docs/operations/external-secrets.md
```

Full runbook: `techx-corp-chart/docs/operations/external-secrets.md`.

Optional tfvars (when cluster API reachable at apply — installs ESO from Terraform instead of manual helm):

```hcl
external_secrets_install_helm                = true
external_secrets_create_cluster_secret_store = true
```

---

## Phase 2b: Argo CD (GitOps control plane — REL-09)

Opt-in: set `argocd_enabled = true` in `environments/<env>/terraform.tfvars` (dev first).  
Requires cluster API reachable during `terraform apply` (kubeconfig + network).

```bash
# tfvars: argocd_enabled = true
terraform -chdir=environments/development plan -out=dev.tfplan
terraform -chdir=environments/development apply "dev.tfplan"

kubectl -n argocd get pods
terraform -chdir=environments/development output -raw argocd_port_forward_command
terraform -chdir=environments/development output -raw argocd_admin_password_command
terraform -chdir=environments/development output -raw argocd_bootstrap_apply_commands
```

- Module: `modules/argocd` (pinned argo-cd chart, ClusterIP, **no** public Ingress).  
- Applications live in **chart** repo: `techx-corp-chart/gitops/clusters/{dev,prod}/`.  
- Repo credentials: create Secret in `argocd` NS (not in Git).  
- Full plan: workspace `docs/gitops-argocd.md`.

---

## Phase 3: Docker Image Build & Push (tham chiếu platform)

*Repo `techx-corp-platform` — không chạy bake trong infra.*

Terraform **chỉ tạo** ECR rỗng. Platform push:

```text
IMAGE_NAME=<ecr_image_base_url>
→ ${IMAGE_NAME}/ad:sha-…   =   REGISTRY/techx-corp/ad:sha-…
```

| Branch / trigger | PROJECT ECR |
|---|---|
| `main` / tag `v*` | `techx-corp` |
| branch `techx-dev-corp` | `techx-dev-corp` |

OIDC: workflow assume role từ bootstrap `github_actions_ecr_*_role_arn` (ECR permissions scoped to `repository/<ecr_project_name>/*`).

---

## Phase 4: Deploy app (GitOps / chart)

**Preferred (REL-09):** commit image tag in `values-prod.yaml` or `values-dev.yaml` → Argo CD sync:

```bash
argocd app sync techx-corp --dry-run
argocd app sync techx-corp
argocd app wait techx-corp --sync --health --timeout 600
```

See `techx-corp-chart/docs/operations/gitops-argocd.md`.

**Break-glass Helm** (disable Argo auto-sync first):

```bash
helm upgrade --install techx-corp techx-corp-chart \
  -n techx-corp --create-namespace \
  -f techx-corp-chart/values-public-alb.yaml \
  -f techx-corp-chart/values-prod.yaml \
  --wait --atomic --timeout 10m --history-max 10
```

- `repository` / `tag` live in env values files (Git), not only operator `--set`
- Primary rollback after GitOps: **git revert**, not Helm rollback
- Chart append `/SERVICE` → full nested image path

### Storefront internal ALB + CloudFront path blocking

The storefront ALB is **internal** (chart `values-public-alb.yaml`: `scheme: internal`, no ALB path-block rules). Public HTTPS and sensitive-path **403**s are on **CloudFront** (VPC origin + Function).

```cmd
terraform -chdir=environments/production output storefront_alb_scheme
terraform -chdir=environments/production output storefront_alb_helm_set_flags
terraform -chdir=environments/production output storefront_alb_security_posture
terraform -chdir=environments/production output cloudfront_block_sensitive_paths
```

Helm break-glass flags always set internal ALB with no path blocks:

```cmd
terraform -chdir=environments/production output storefront_alb_helm_set_flags
REM → --set components.frontend-proxy.publicAlb.scheme=internal --set …blockSensitivePaths=false
```

Path blocking at the edge (Terraform):

```hcl
cloudfront_block_sensitive_paths = true   # or false
# cloudfront_blocked_prefixes    = ["/grafana", "/jaeger", …]
```

### CloudFront edge (internal ALB VPC origin)

Optional HTTPS edge. Off by default (`cloudfront_enabled = false`). When enabled: ACM ARN (`us-east-1`), **internal** ALB DNS + **ALB ARN** (VPC origin), and aliases.

Full runbook: **[docs/cloudfront.md](./cloudfront.md)**.

```cmd
cd /d techx-corp-infra
REM After setting cloudfront_* (including cloudfront_origin_alb_arn) in terraform.tfvars:
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output cloudfront_domain_name
terraform -chdir=environments/production output cloudfront_vpc_origin_id
```

### Client VPN (private admin paths on the same internal ALB)

Admin/telemetry prefixes remain **403 on CloudFront**. Operators connect via **AWS Client VPN** and use the **internal ALB** DNS (no second ALB). Off by default (`client_vpn_enabled = false`) because of association hours.

Full runbook (including **prerequisites setup for both ACM certs**): **[docs/client-vpn.md](./client-vpn.md)**.

**Prerequisites before enable (summary):**

1. **Import** (not Request) two certs into ACM `us-east-1` — ACM always needs `--private-key`:
   - Server leaf + key (+ chain) → `client_vpn_server_certificate_arn`
   - Client CA cert + CA key → `client_vpn_client_ca_arn`
2. Keep per-operator client cert/key for the `.ovpn` file (not imported to ACM).
3. Recommended: set `client_vpn_alb_security_group_ids` from the storefront ALB SGs (TCP 80 from client CIDR).
4. Optional: leave `client_vpn_subnet_ids` empty for one-AZ association (cost).

```cmd
cd /d techx-corp-infra
REM After prerequisites setup in docs/client-vpn.md and real ARNs in terraform.tfvars:
terraform -chdir=environments/production plan -out=tfplan
terraform -chdir=environments/production apply tfplan
terraform -chdir=environments/production output client_vpn_endpoint_id
terraform -chdir=environments/production output client_vpn_export_client_config_command
```

---

## Phase 5–6: Verify & Rollback (tham chiếu chart)

Smoke test + `helm rollback` — xem `techx-corp-chart/docs/DEPLOYMENT.md`.

---

## Modules liên quan

| Module | Chức năng |
|---|---|
| `modules/ecr` | Nested (hoặc flat) ECR + lifecycle + catalog services |
| `modules/github-actions-ecr` | IAM role ECR push (OIDC provider lives in `bootstrap/`) |
| `modules/vpc` | VPC, subnets, NAT, EKS + Karpenter discovery subnet tags |
| `modules/eks` | EKS, node groups, EKS OIDC (IRSA), ALB controller role, cluster SG discovery tag |
| `modules/karpenter` | Karpenter IRSA, node role, SQS interruption, Helm, NodePool/EC2NodeClass |
| `modules/secrets-manager` | ASM secret shells (metadata only; no secret values) |
| `modules/external-secrets` | ESO IRSA + optional Helm/ClusterSecretStore |
| `modules/cloudfront-alb` | CloudFront + VPC origin + optional path-block Function |
| `modules/client-vpn` | Optional Client VPN for private admin access to internal ALB |

---

## Troubleshooting

### 1. State lock

```bash
terraform -chdir=environments/production force-unlock <LOCK_ID>
```

### 2. OIDC provider / GHA roles already exist (state move)

GitHub OIDC + ECR push roles moved from environment stacks into `bootstrap/`. If they already exist in AWS from a previous env apply:

1. Remove from environment state **without destroy** (`terraform state rm …`).
2. Import into bootstrap state (see change doc migration notes).
3. Or import existing OIDC provider into bootstrap if it was created out-of-band.

Do **not** create a second account-level OIDC provider for `token.actions.githubusercontent.com`.

### 3. GHA không assume được role

- Trust `sub` phải khớp:  
  `repo:tmcmanhcuong/tf2-corp-platform:environment:production`  
  (hoặc `development`, hoặc `ref:refs/heads/main`, …)
- Bootstrap output: `github_actions_allowed_subjects`

### 4. AWS Load Balancer Controller CrashLoop / IMDS timeout

Symptom in controller logs:

```text
unable to initialize AWS cloud
failed to get VPC ID: ... ec2imds: GetMetadata, canceled, context deadline exceeded
```

**Cause:** controller tried to discover VPC/region via instance metadata; pods often cannot reach IMDS (hop limit 1).

**Fix:** reinstall using Terraform output (sets `region` + `vpcId` + IRSA):

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
terraform -chdir=environments/production output -raw aws_load_balancer_controller_helm_command
# run printed command, then:
kubectl -n kube-system rollout restart deployment/aws-load-balancer-controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

Also verify IRSA on the service account:

```bash
kubectl get sa aws-load-balancer-controller -n kube-system -o yaml
# must include: eks.amazonaws.com/role-arn: arn:aws:iam::...:role/...-alb-controller-role
```

### 5. Helm: another operation is in progress (ESO / any release)

Symptom:

```text
Error: UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress
```

Diagnose:

```bash
helm status external-secrets -n external-secrets
helm history external-secrets -n external-secrets --max 5
# Common: STATUS pending-install or pending-upgrade while pods may already be Running
```

**Cause:** previous `helm upgrade --install ... --wait` was interrupted (client disconnect, Ctrl+C, timeout, network blip). Helm left the release locked mid-operation.

**Fix** (when only revision is stuck pending-install, or no healthy deployed revision):

```bash
helm uninstall external-secrets -n external-secrets --wait --timeout 5m

# Re-run install from Terraform output (do not interrupt --wait)
terraform -chdir=environments/development output -raw external_secrets_helm_command
# paste/run the printed command

helm status external-secrets -n external-secrets
# expect STATUS: deployed
kubectl -n external-secrets get pods
kubectl get sa external-secrets -n external-secrets -o yaml | findstr /i role-arn
# Linux/mac:  ... | grep role-arn
```

Notes:

- Do **not** run a second `helm upgrade` while STATUS is still `pending-*`.
- CRDs usually remain after uninstall; reinstall with `installCRDs=true` is still fine.
- If you have a **prior successful** revision and are stuck on pending-upgrade, try `helm rollback external-secrets <last-deployed-rev> -n external-secrets` before uninstall.

### 6. ImagePullBackOff sau deploy

- Repo nested đã tạo?  
  `aws ecr describe-repositories --repository-names techx-corp/ad --region us-east-1`
- Image format: `.../techx-corp/ad:sha-…` không phải `.../techx-corp:sha-…-ad`
- Node role ECR pull policy

### 7. Plan destroy monorepo ECR cũ

Nếu state còn `techx-corp` (flat), plan sẽ destroy và tạo `techx-corp/*`.  
Backup images cần thiết trước apply; lifecycle `force_delete` cho phép xóa repo không rỗng.

### 8. State corruption

```bash
aws s3api list-object-versions \
  --bucket techx-tf-state-493499579600-us-east-1 \
  --prefix production/terraform.tfstate
```

---

## Tài liệu liên quan

- [USAGE_GUIDE.md](./USAGE_GUIDE.md) — thao tác Terraform hàng ngày  
- `techx-corp-platform/docs/CICD.md` — GitHub Actions  
- `techx-corp-platform/docs/DEPLOYMENT.md` — E2E operator runbook  
- `techx-corp-chart/docs/DEPLOYMENT.md` — Helm / smoke / rollback  
