# Backlog: SEC-05 - Nền tảng AWS Secrets Manager + ESO IRSA (Infra level)

## Bối cảnh

Hạ tầng `techx-corp-infra` hiện có EKS, OIDC/IRSA cho AWS Load Balancer Controller, nhưng **chưa** có AWS Secrets Manager cho application credentials, **chưa** cài External Secrets Operator (ESO), và **chưa** có IRSA cho controller đồng bộ secret. SEC-05 yêu cầu nền tảng cloud/cluster để chart có thể fetch credential từ Secrets Manager thay vì plaintext trong Git.

Kế hoạch tổng thể: [`docs/eso-aws-secrets-manager.md`](../../../docs/eso-aws-secrets-manager.md)  
Backlog tổng: [`docs/backlogs/2026-07-09-sec-05-eso-aws-secrets-manager.md`](../../../docs/backlogs/2026-07-09-sec-05-eso-aws-secrets-manager.md)

## Vấn đề

1. Không có resource Terraform cho secret application trên ASM.
2. Không có IAM role IRSA dành cho ServiceAccount của ESO.
3. Không có quy trình cài ESO + `ClusterSecretStore` gắn region `us-east-1` và JWT/IRSA.
4. Nếu Terraform ghi password bằng `random_password` + `aws_secretsmanager_secret_version`, giá trị vẫn nằm trong **Terraform state** — `ignore_changes` **không** loại bỏ secret khỏi state.
5. IAM quá rộng (`ListSecrets`, wildcard `techx-corp/*`) làm tăng blast radius khi dùng ClusterSecretStore.

## Giải pháp đề xuất

1. **Module Secrets Manager (metadata only)**  
   - Tạo `aws_secretsmanager_secret` cho:
     - `techx-corp/{env}/postgresql-admin`
     - `techx-corp/{env}/postgresql-app`
     - `techx-corp/{env}/flagd-ui`
     - `techx-corp/{env}/product-reviews`
     - `techx-corp/{env}/grafana`
   - Quản lý: name, ARN, tags, KMS (nếu có), recovery window.  
   - **Không** populate `secret_string` / `random_password` cho production trong Terraform.  
   - Giá trị do bootstrap ngoài TF: CLI/CI hạn quyền / Console có audit (`put-secret-value`).

2. **IRSA cho ESO** (mẫu theo `modules/eks/alb-controller.tf`)  
   - Role: `{cluster_name}-external-secrets`  
   - Trust: SA namespace `external-secrets` (tên SA theo chart ESO đã pin)  
   - Policy tối thiểu:
     - `secretsmanager:GetSecretValue`
     - `secretsmanager:DescribeSecret`
     - trên **ARN secret cụ thể**  
   - Chỉ thêm `ListSecrets` / `kms:Decrypt` khi thực sự cần.

3. **Cài ESO**  
   - Namespace `external-secrets`, Helm chart official, **pin version**.  
   - Gắn annotation `eks.amazonaws.com/role-arn` lên ServiceAccount controller.  
   - Ưu tiên `helm_release` Terraform hoặc lệnh cài từ output (giống ALB controller).

4. **ClusterSecretStore** `aws-secretsmanager`  
   - Provider AWS Secrets Manager, region `us-east-1`, auth JWT → SA ESO.  
   - Ghi chú single-tenant: siết RBAC create ExternalSecret; multi-tenant sau này cân nhắc SecretStore theo namespace.

5. **Outputs & tài liệu**  
   - Output: `eso_role_arn`, secret ARNs, hướng dẫn bootstrap (không in password).  
   - Cập nhật `docs/DEPLOYMENT.md`: Phase secrets/ESO trước deploy app chart.  
   - **Phase foundation không tạo password Postgres mới** — chart cutover dùng credential đang live.

## Acceptance Criteria

- [ ] Terraform apply (dev trước, rồi prod) tạo đủ ASM secret containers + IRSA ESO.
- [ ] State/plan **không** chứa production secret values do TF generate.
- [ ] ESO pod Running; SA có annotation role ARN đúng.
- [ ] `ClusterSecretStore` Ready.
- [ ] IAM chỉ Get/Describe trên ARN cần thiết (least privilege).
- [ ] Output/runbook bootstrap `put-secret-value` có audit, tách khỏi `terraform apply`.
- [ ] Tài liệu DEPLOYMENT nêu thứ tự: ESO → Store → ExternalSecret (chart) → app.

## Kiểm thử / xác minh

```sh
terraform -chdir=enviroments/development plan
terraform -chdir=enviroments/development apply

# Không expect secret_string app password trong state
aws secretsmanager list-secrets --region us-east-1 \
  --filters Key=name,Values=techx-corp/development

kubectl -n external-secrets get deploy,sa
kubectl -n external-secrets describe sa external-secrets | findstr /i role-arn
kubectl get clustersecretstore aws-secretsmanager -o yaml
```

Canary (sau khi chart/ops đưa ExternalSecret):

```sh
kubectl -n techx-corp wait --for=condition=Ready externalsecret --all --timeout=120s
```

## Rủi ro & rollback

- **Rủi ro**: Trust IRSA sai SA/namespace → ESO AccessDenied; ClusterSecretStore + ARN rộng → exfiltration nếu RBAC lỏng; nhầm populate password mới khi Postgres đã init.
- **Rollback**: Gỡ `helm_release` ESO / xóa ClusterSecretStore; giữ ASM secret containers; không ảnh hưởng app nếu chart chưa cutover.  
- **Không** “sửa” bằng cách đưa password vào Terraform state.

---

## English Summary

Infra-level SEC-05: Terraform creates AWS Secrets Manager **secret shells only**, ESO IRSA with least-privilege Get/Describe on exact ARNs, installs External Secrets Operator, and applies ClusterSecretStore. Secret values are bootstrapped outside Terraform. No new Postgres passwords in foundation phase. Full plan: workspace `docs/eso-aws-secrets-manager.md`.
