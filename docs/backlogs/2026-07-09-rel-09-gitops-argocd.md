# Backlog: REL-09 - Cài Argo CD control plane (Infra level)

## Bối cảnh

EKS đã có OIDC/IRSA và ALB controller; chưa có GitOps controller. REL-09 yêu cầu cài **Argo CD** (pin version) trên từng cluster qua Terraform, không public UI.

Kế hoạch: [`docs/gitops-argocd.md`](../../../docs/gitops-argocd.md)

## Vấn đề

1. Không có nơi cài Argo CD lặp lại được (dev/prod).  
2. Cần pin chart version và opt-in (`argocd_enabled`) để không phá apply hiện tại.  
3. Apply Helm in-cluster cần provider kubernetes/helm + EKS auth.

## Giải pháp

1. Module `modules/argocd`: `helm_release` argo-cd pin version, namespace `argocd`, ClusterIP, Ingress off.  
2. Wire `enviroments/{development,production}` với `argocd_enabled` (default **false**).  
3. Outputs: port-forward, admin password command, bootstrap note.  
4. Dev bật trước; prod sau khi cutover dev ổn.  
5. Không quản app-of-apps bằng TF v1 — Application apply từ chart `gitops/`.

## Acceptance Criteria

- [ ] Module argocd + versions helm/kubernetes.  
- [ ] `argocd_enabled=false` mặc định; bật được bằng tfvars.  
- [ ] Outputs bootstrap + port-forward.  
- [ ] DEPLOYMENT.md mô tả phase cài Argo CD.  
- [ ] Không public Ingress cho argocd-server.

## Kiểm thử

```sh
# tfvars: argocd_enabled = true
terraform -chdir=enviroments/development plan
terraform -chdir=enviroments/development apply
kubectl -n argocd get pods
# theo output port_forward_command / admin_password_command
```

## Rủi ro & rollback

| Rủi ro | Giảm thiểu |
|--------|------------|
| Apply không reach API EKS | default enabled=false; kubeconfig trước apply |
| Upgrade chart breaking | pin version; thử dev |
| Rollback | `argocd_enabled=false` không tự gỡ release — destroy helm_release có chủ đích hoặc helm uninstall |

---

## English Summary

Infra REL-09: Terraform module installs pinned Argo CD (opt-in), ClusterIP only, outputs for bootstrap. Applications live in the chart repo.
