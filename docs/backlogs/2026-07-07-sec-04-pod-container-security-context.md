# Backlog: SEC-04 - Chuẩn hóa pod/container security context (Infra level - Cluster Support)

## Bối cảnh
Để củng cố an toàn hạ tầng và áp dụng các tiêu chuẩn bảo mật tối thiểu Restricted trên cụm Kubernetes của TechX Corp, hạ tầng cụm EKS cần sẵn sàng hỗ trợ cơ chế Pod Security Admission (PSA) để kiểm duyệt và cưỡng chế các cấu hình Security Context của workload.

## Vấn đề
Việc kích hoạt chính sách bảo mật Restricted ở mức độ toàn cụm (cluster-wide) mà không có sự chuẩn bị có thể gây lỗi nghiêm trọng, ngăn cản các tài nguyên hệ thống (system workloads trong `kube-system`) hay các agent đo lường (observability daemonsets cần lấy thông số node) khởi chạy. Hạ tầng cần một chiến lược rollout và giám sát PSA rõ ràng ở cấp namespace để phân loại và cô lập các chính sách bảo mật mà không làm gián đoạn hạ tầng dùng chung.

## Giải pháp đề xuất
1. **Thiết lập chính sách Pod Security Admission (PSA) cấp Namespace:**
   - Áp dụng Restricted profile cho namespace chứa ứng dụng nghiệp vụ (ví dụ: `techx-corp`).
   - Gán nhãn kiểm duyệt bảo mật cho các namespace ứng dụng:
     ```yaml
     pod-security.kubernetes.io/enforce: restricted
     pod-security.kubernetes.io/enforce-version: latest
     pod-security.kubernetes.io/warn: restricted
     pod-security.kubernetes.io/warn-version: latest
     ```
2. **Miễn trừ các Namespace hệ thống và hạ tầng đặc quyền:**
   - Giữ nguyên hoặc cấu hình chính sách `privileged` đối với namespace `kube-system` và các namespace quản lý AWS controllers (AWS Load Balancer Controller) do các dịch vụ này bắt buộc phải giao tiếp trực tiếp với host network và API AWS.
3. **Lộ trình triển khai (Rollout Stages):**
   - **Giai đoạn 1 (Audit/Warn):** Chỉ bật chế độ `warn` và `audit` trên namespace ứng dụng để ghi nhận các cảnh báo không tương thích mà không block việc deploy.
   - **Giai đoạn 2 (Enforce):** Bật chế độ `enforce` sau khi toàn bộ Helm chart và Custom Images đã được cập nhật thành công ở phase platform và chart.
4. **Cung cấp công cụ kiểm tra (Validation Tools):**
   - Đưa ra các lệnh sử dụng `kubectl` để liệt kê các pod vi phạm tiêu chuẩn bảo mật trước khi nâng cấp chính sách lên enforce.
5. **Lưu ý triển khai:** Terraform code phục vụ cho việc tạo tài nguyên hạ tầng sẽ không sửa đổi trong backlog này cho đến khi có yêu cầu cụ thể ở các story tiếp theo.

## Acceptance Criteria
- Tài liệu xác định rõ ràng phương án gán nhãn PSA cho từng nhóm namespace (app namespace vs system namespace).
- Tài liệu làm rõ các exception được phép chạy đặc quyền (như AWS ALB controller, observability agents thu thập host metrics) để tránh làm gián đoạn vận hành hệ thống.
- Cung cấp các câu lệnh kiểm tra tính tuân thủ cụ thể để DevOps/SecOps có thể quét lỗi bảo mật trên cluster.

## Kiểm thử / xác minh
1. Lệnh kiểm tra và gán thử nhãn cảnh báo (warn) trên namespace thử nghiệm:
   ```sh
   kubectl label namespace techx-corp pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/warn-version=latest --overwrite
   ```
2. Lệnh liệt kê các cảnh báo của các pod hiện tại khi áp dụng Restricted:
   ```sh
   kubectl get pods -n techx-corp -o json | jq '.items[].metadata.name' # kiểm tra log của cluster API audit
   ```

## Rủi ro & rollback
- **Rủi ro**: Thiết lập nhầm chính sách Restricted trên `kube-system` có thể làm hỏng các dịch vụ thiết yếu như CoreDNS, kube-proxy, aws-node, khiến cụm EKS mất kết nối hoàn toàn.
- **Rollback**: Gỡ bỏ nhãn PSA hoặc đặt lại về `privileged`:
   ```sh
   kubectl label namespace <namespace> pod-security.kubernetes.io/enforce-
   # Hoặc chuyển sang privileged
   kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged --overwrite
   ```

---

## English Summary
This backlog describes cluster-level readiness and enforcement strategies for Pod Security Admission (PSA) in the `techx-corp-infra` repository. It focuses on EKS cluster namespace isolation policies, ensuring restricted policies are applied to application namespaces (`techx-corp`) while system namespaces (`kube-system`) remain privileged to prevent cluster downtime. It defines a multi-stage rollout plan (audit/warn first, then enforce) and provides validation commands for cluster administrators without modifying Terraform resources.
