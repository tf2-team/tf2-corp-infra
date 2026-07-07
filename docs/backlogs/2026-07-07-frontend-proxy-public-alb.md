# Backlog: Public ALB Ingress cho frontend-proxy

## Bối cảnh
Hệ thống TechX Corp đang chạy trên hạ tầng AWS EKS nhưng hiện tại chưa expose public endpoint cho storefront của frontend-proxy một cách an toàn. Để chuẩn bị cho việc public sản phẩm, chúng ta cần cấu hình một AWS Application Load Balancer (ALB) trước frontend-proxy, đồng thời đảm bảo kiểm soát truy cập nghiêm ngặt.

## Vấn đề
Hiện tại, repo `techx-corp-infra` chưa có cơ chế hoàn chỉnh để tích hợp AWS Load Balancer Controller. Controller này là điều kiện bắt buộc để Kubernetes tự động tạo và cấu hình AWS ALB khi một tài nguyên Ingress được định nghĩa. Việc thiếu cấu hình IAM OIDC Provider và chính sách bảo mật tối thiểu (least privilege) cho service account có thể dẫn đến việc cấu hình ALB thất bại hoặc rủi ro bảo mật do cấp quyền quá rộng.

## Giải pháp đề xuất
Triển khai tích hợp IAM Roles for Service Accounts (IRSA) cho AWS Load Balancer Controller:
1. Thêm cấu hình provider `tls` để phục vụ việc trích xuất thumbprint từ tổ chức phát hành chứng chỉ OIDC của cluster.
2. Thiết lập EKS OIDC Provider (`aws_iam_openid_connect_provider`) để cho phép Kubernetes ServiceAccount xác thực với AWS IAM qua Web Identity.
3. Tạo IAM Policy chuyên dụng cho AWS Load Balancer Controller bằng cách tải và đóng gói tệp chính sách chuẩn của AWS (`iam-policy.json`).
4. Khai báo IAM Role và gắn kết chính sách để cấp quyền cho service account `kube-system/aws-load-balancer-controller`.
5. Tạo Terraform output cung cấp Role ARN và câu lệnh Helm chuẩn để cài đặt controller.

> [!NOTE]
> File local `tfplan` được tạo ra trong quá trình kiểm thử cục bộ chỉ là artifact phục vụ dev và KHÔNG được commit lên git repository. Nó cần được dọn dẹp hoặc tạo lại khi triển khai thực tế.

## Acceptance Criteria
- Cấu hình Terraform hoàn thành kiểm tra định dạng (`terraform fmt -check`).
- Cấu hình Terraform xác thực cú pháp thành công (`terraform validate`).
- Lệnh `terraform plan` được review và không phát sinh lỗi bất thường.
- AWS Load Balancer Controller chạy ổn định (`healthy`) trong namespace `kube-system` sau khi chạy lệnh Helm tương ứng.

## Kiểm thử / xác minh
1. Khởi tạo Terraform và thực hiện kiểm tra cú pháp:
   ```sh
   terraform init
   terraform validate
   ```
2. Thực hiện tạo bản kế hoạch chạy thử và đảm bảo không có cảnh báo nghiêm trọng:
   ```sh
   terraform plan -out=tfplan
   ```
3. Sau khi áp dụng Terraform, kiểm tra output để lấy lệnh cài đặt Helm và chạy lệnh đó. Kiểm tra trạng thái controller:
   ```sh
   kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
   ```

## Rủi ro & rollback
- **Rủi ro**: Lỗi thumbprint OIDC hoặc sai lệch cấu hình ARN trong annotation của ServiceAccount khiến Controller không có quyền tạo ALB.
- **Rollback**: Gỡ cài đặt Helm release của controller, sau đó thực hiện `terraform destroy` các tài nguyên liên quan đến OIDC và IAM Role của controller. Đảm bảo không làm ảnh hưởng đến các IAM role khác của EKS cluster.

---

## English Summary
This backlog tracks the infrastructure changes required to support the AWS Load Balancer Controller and IRSA configuration in the `techx-corp-infra` repository. It registers the work-in-progress configuration of the TLS provider, EKS OIDC identity provider, IAM policy, and IAM role. The output Helm installation command must be made available for operational deployment. No `tfplan` files should be committed as they are local artifacts.
