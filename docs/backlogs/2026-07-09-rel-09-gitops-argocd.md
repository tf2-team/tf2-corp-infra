# Backlog: REL-09 - Cài Argo CD control plane (Infra level)

## Bối cảnh

Hạ tầng `techx-corp-infra` đã có EKS, OIDC/IRSA, ALB controller IAM. Chưa có GitOps controller. REL-09 yêu cầu cài **Argo CD** (pin version) trên từng cluster qua Terraform, opt-in, không public UI.

- Kế hoạch tổng: [`docs/gitops-argocd.md`](../../../docs/gitops-argocd.md)
- Backlog tổng: [`docs/backlogs/2026-07-09-rel-09-gitops-argocd.md`](../../../docs/backlogs/2026-07-09-rel-09-gitops-argocd.md)

## Vấn đề

1. Không có module lặp lại được để cài Argo CD trên dev/prod.
2. Cần pin chart version và cờ `argocd_enabled` để không phá apply hiện tại.
3. `helm_release` in-cluster cần provider `kubernetes`/`helm` + EKS auth tại apply time.
4. UI không được expose qua public storefront ALB.

## Giải pháp đề xuất (infra)

1. **Module `modules/argocd`**  
   - Namespace `argocd`  
   - Helm chart `argo-cd` (pin, ví dụ `7.8.28`)  
   - Server ClusterIP; Ingress **disabled**  
   - ApplicationSet / notifications off mặc định (Phase 7)  

2. **Wire env** `environments/development` & `production`  
   - `argocd_enabled` (default **false**)  
   - `argocd_chart_version`, `argocd_chart_repo_url` (document)  
   - Provider kubernetes/helm dùng EKS token  

3. **Outputs**  
   - port-forward command  
   - admin password command  
   - bootstrap apply commands (trỏ chart `gitops/clusters/`)  

4. **Thứ tự**  
   - Bật dev trước; prod sau khi cutover dev ổn.  
   - Application CRs **không** quản bằng TF v1 — nằm trong chart repo.

## Acceptance Criteria

- [ ] Module `argocd` + required_providers helm/kubernetes.
- [ ] `argocd_enabled=false` mặc định; bật được qua tfvars.
- [ ] Outputs: port-forward, admin password, bootstrap note/commands.
- [ ] `docs/DEPLOYMENT.md` có Phase 2b Argo CD.
- [ ] Không public Ingress cho `argocd-server`.
- [ ] Pin chart version; upgrade chỉ sau validate dev.

## Kiểm thử / xác minh

```sh
# tfvars: argocd_enabled = true
terraform -chdir=environments/development plan
terraform -chdir=environments/development apply

kubectl -n argocd get pods
terraform -chdir=environments/development output argocd_port_forward_command
terraform -chdir=environments/development output argocd_bootstrap_apply_commands
```

## Rủi ro & rollback

| Rủi ro | Giảm thiểu |
|--------|------------|
| Apply không reach EKS API | default enabled=false; kubeconfig trước apply |
| Chart upgrade breaking | pin version; thử dev |
| Gỡ control plane | chủ đích `helm uninstall` / destroy module — không flip flag rồi quên cleanup |

---

## English Summary

Infra-level REL-09: Terraform module installs pinned Argo CD (opt-in), ClusterIP only, bootstrap outputs. Application manifests live in the chart repo.
