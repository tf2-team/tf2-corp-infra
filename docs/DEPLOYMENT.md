# Tài liệu Hướng dẫn Triển khai End-to-End (Production Runbook)

> [!NOTE]
> **Vai trò của Repository này (`techx-corp-infra`):**
> Repository này chịu trách nhiệm **Terraform**: bootstrap remote state, VPC, EKS, **nested ECR** (`techx-corp/*`, `techx-dev-corp/*`), **GitHub Actions OIDC roles** (push image), và IAM cho AWS Load Balancer Controller.

---

## 1. Mục tiêu (Objectives)

- Bootstrap S3 remote state (encrypted, lockfile).
- Provision production & development stacks.
- Tạo **đủ ECR repository** theo format image:
  ```text
  [REGISTRY]/[PROJECT]/[SERVICE]:[VERSION]
  ```
- Cung cấp IAM role cho GitHub Actions push image (OIDC, không access key dài hạn).
- Xuất outputs cho platform CI/CD và chart Helm.

## 2. Bản đồ Repository

| Repository | Vai trò |
|---|---|
| **`techx-corp-infra`** | Terraform: state, network, EKS, ECR nested, GHA OIDC, ALB IAM |
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
| `ecr_project_name` | `techx-corp` |
| Nested repos | `techx-corp/ad`, `techx-corp/checkout`, … |
| Image base | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp` |
| EKS | `techx-tf2` |
| GHA role | `techx-gha-platform-prod` |
| GitHub Environment (OIDC sub) | `production` |
| Allowed refs | `refs/heads/main`, `refs/tags/v*` |
| Creates GitHub OIDC provider | **yes** (account singleton) |
| State key | `production/terraform.tfstate` |

### Development (`environments/development`)

| Hằng số | Giá trị |
|---|---|
| `project_name` | `techx-dev` |
| `ecr_project_name` | `techx-dev-corp` |
| Nested repos | `techx-dev-corp/ad`, … |
| Image base | `493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-dev-corp` |
| EKS | `techx-dev` |
| GHA role | `techx-gha-platform-dev` |
| GitHub Environment | `development` |
| Allowed refs | `refs/heads/techx-dev-corp` |
| Creates GitHub OIDC provider | **no** (lookup provider đã tạo bởi production) |
| State key | `development/terraform.tfstate` |

### Catalog ECR services (module `modules/ecr`)

Một repo nested cho mỗi service bake (đồng bộ platform compose):

`accounting`, `ad`, `cart`, `checkout`, `currency`, `email`, `fraud-detection`, `frontend`, `frontend-proxy`, `image-provider`, `load-generator`, `payment`, `product-catalog`, `product-reviews`, `quote`, `recommendation`, `shipping`, `flagd-ui`, `kafka`, `llm`, `opensearch`

Ví dụ tên repo AWS:

```text
techx-corp/ad
techx-corp/frontend
techx-dev-corp/checkout
```

Image đầy đủ (sau khi platform push):

```text
493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp/ad:sha-a1b2c3d
```

> **Migration note:** Định dạng monorepo cũ (`techx-corp` một repo, tag `1.0-ad`) đã thay bằng nested. Plan có thể **destroy** repo flat cũ và **create** nhiều repo nested — review plan kỹ.

---

## Phase 1: Bootstrap Remote State

> [!CAUTION]
> 1. Không commit state cục bộ / `backend.hcl` thật.  
> 2. Production: luôn `plan -out` → review → `apply` artifact.  
> 3. Apply **production trước development** (OIDC provider GitHub).

### Bước 1: Bootstrap

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap plan -out=bootstrap.tfplan
terraform -chdir=bootstrap apply "bootstrap.tfplan"
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

- `module.ecr.aws_ecr_repository.this["ad"]` → name `techx-corp/ad` (× full catalog)
- `module.github_actions_ecr.aws_iam_openid_connect_provider.github` (nếu chưa có)
- `module.github_actions_ecr.aws_iam_role.this` → `techx-gha-platform-prod`
- VPC / EKS / ALB controller role

```bash
terraform -chdir=environments/production apply "prod.tfplan"
```

### Bước 3: Development stack

```bash
# backend.hcl key = "development/terraform.tfstate"
terraform -chdir=environments/development init -backend-config=backend.hcl
terraform -chdir=environments/development plan -out=dev.tfplan
# Kỳ vọng: techx-dev-corp/<service>, role techx-gha-platform-dev, KHÔNG tạo lại OIDC provider
terraform -chdir=environments/development apply "dev.tfplan"
```

### Bước 4: Outputs cho CI/CD & Helm

```bash
# Production
terraform -chdir=environments/production output ecr_image_base_url
# 493499579600.dkr.ecr.us-east-1.amazonaws.com/techx-corp

terraform -chdir=environments/production output ecr_service_names
terraform -chdir=environments/production output ecr_repository_names
terraform -chdir=environments/production output github_actions_ecr_role_arn
terraform -chdir=environments/production output github_actions_allowed_subjects
terraform -chdir=environments/production output aws_load_balancer_controller_role_arn
terraform -chdir=environments/production output -raw aws_load_balancer_controller_helm_command

# Development
terraform -chdir=environments/development output ecr_image_base_url
# .../techx-dev-corp
terraform -chdir=environments/development output github_actions_ecr_role_arn
```

**Gán GitHub Environments** (repo platform):

| GitHub Environment | `AWS_ROLE_ARN` | `IMAGE_NAME` |
|---|---|---|
| `production` | output prod `github_actions_ecr_role_arn` | output prod `ecr_image_base_url` |
| `development` | output dev `github_actions_ecr_role_arn` | output dev `ecr_image_base_url` |

Chi tiết workflow: `techx-corp-platform/docs/CICD.md`.

---

## Phase 2: Kubeconfig & Load Balancer Controller

```bash
aws eks update-kubeconfig --region us-east-1 --name techx-tf2
kubectl get nodes

helm repo add eks https://aws.github.io/eks-charts && helm repo update
terraform -chdir=environments/production output -raw aws_load_balancer_controller_helm_command
# Chạy lệnh in ra
kubectl get deployment -n kube-system aws-load-balancer-controller
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

OIDC: workflow assume role từ `github_actions_ecr_role_arn` (permissions đã scope toàn bộ nested repo ARNs của stack).

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

### Storefront ALB path blocking (Terraform flag → Helm)

IaC toggle (does not create AWS rules by itself; applied via Helm Ingress):

```hcl
# environments/production/terraform.tfvars (or development)
storefront_alb_block_sensitive_paths = true   # or false
```

```bash
terraform -chdir=environments/production output storefront_alb_block_sensitive_paths
terraform -chdir=environments/production output storefront_alb_helm_set_flags
terraform -chdir=environments/production output storefront_alb_security_posture
```

If the app Helm release is **already installed**, toggle **only** the block flag (no image change):

```bash
# ON
helm upgrade techx-corp techx-corp-chart \
  -n techx-corp \
  --reuse-values \
  --set components.frontend-proxy.publicAlb.blockSensitivePaths=true \
  --wait --timeout 5m

# OFF
helm upgrade techx-corp techx-corp-chart \
  -n techx-corp \
  --reuse-values \
  --set components.frontend-proxy.publicAlb.blockSensitivePaths=false \
  --wait --timeout 5m
```

Posture when ON: ALLOW `/`, `/api/*`, `/images/*` · BLOCK `/grafana`, `/jaeger`, `/loadgen`, `/feature`, `/flagservice`, `/otlp-http` (HTTP 403).

---

## Phase 5–6: Verify & Rollback (tham chiếu chart)

Smoke test + `helm rollback` — xem `techx-corp-chart/docs/DEPLOYMENT.md`.

---

## Modules liên quan

| Module | Chức năng |
|---|---|
| `modules/ecr` | Nested (hoặc flat) ECR + lifecycle + catalog services |
| `modules/github-actions-ecr` | GitHub OIDC provider (optional) + IAM role ECR push |
| `modules/vpc` | VPC, subnets, NAT, EKS subnet tags |
| `modules/eks` | EKS, node groups, EKS OIDC (IRSA), ALB controller role |

---

## Troubleshooting

### 1. State lock

```bash
terraform -chdir=environments/production force-unlock <LOCK_ID>
```

### 2. OIDC provider already exists (development)

Development đặt `create_github_oidc_provider = false` và lookup URL `token.actions.githubusercontent.com`.  
Nếu apply dev **trước** prod: set `create_github_oidc_provider = true` một lần, hoặc import provider hiện có.

### 3. GHA không assume được role

- Trust `sub` phải khớp:  
  `repo:tmcmanhcuong/tf2-corp-platform:environment:production`  
  (hoặc `development`, hoặc `ref:refs/heads/main`, …)
- Output: `github_actions_allowed_subjects`

### 4. ImagePullBackOff sau deploy

- Repo nested đã tạo?  
  `aws ecr describe-repositories --repository-names techx-corp/ad --region us-east-1`
- Image format: `.../techx-corp/ad:sha-…` không phải `.../techx-corp:sha-…-ad`
- Node role ECR pull policy

### 5. Plan destroy monorepo ECR cũ

Nếu state còn `techx-corp` (flat), plan sẽ destroy và tạo `techx-corp/*`.  
Backup images cần thiết trước apply; lifecycle `force_delete` cho phép xóa repo không rỗng.

### 6. State corruption

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
