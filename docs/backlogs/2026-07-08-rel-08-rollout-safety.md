# Backlog: REL-08 - Thiết kế rollback và rollout safety chuẩn hơn

## Bối cảnh
Quy trình triển khai ứng dụng TechX Corp trên hạ tầng EKS (Amazon Elastic Kubernetes Service) cần đảm bảo tính nhất quán và an toàn tối đa. Người vận hành hệ thống (operator) cần có các hướng dẫn và công cụ hạ tầng chuẩn hóa để quản lý việc cập nhật phiên bản, theo dõi trạng thái sức khỏe của tài nguyên và khôi phục nhanh chóng khi có sự cố.

## Vấn đề
- Quá trình deploy hiện tại của operator chưa áp dụng các tham số tự động phục hồi của Helm như `--wait` và `--atomic`, dẫn đến nguy cơ hệ thống rơi vào trạng thái lỗi dở dang (broken state) nếu có Pod khởi động thất bại.
- Thiếu các hướng dẫn hạ tầng về cách kiểm tra tính sẵn sàng của namespace, trạng thái target group của AWS ALB, cũng như các câu lệnh xác thực nhanh sau khi cập nhật hoặc rollback.
- Chưa có quy chuẩn lưu trữ lịch sử release (`--history-max`), gây phình to cấu hình metadata trong Kubernetes cluster sau nhiều lần deploy.

## Giải pháp đề xuất
1. **Chuẩn hóa lệnh deploy của Operator**: Yêu cầu operator triển khai qua lệnh Helm có tích hợp các cơ chế kiểm soát hạ tầng chặt chẽ:
   ```sh
   helm upgrade --install techx-corp techx-corp-chart \
     -n techx-corp --create-namespace \
     --wait --atomic --timeout 10m --history-max 10
   ```
2. **Xác lập điều kiện tiên quyết trước khi deploy**:
   - Kiểm tra trạng thái sẵn sàng của namespace `techx-corp`.
   - Kiểm tra danh sách Pod hiện tại và ghi lại lịch sử phiên bản (`helm history`).
   - Sao lưu (backup) các cấu hình values đang chạy thực tế (`helm get values`).
3. **Định nghĩa các Rollback Triggers (Điều kiện kích hoạt rollback)**:
   - Helm nâng cấp bị quá thời gian (timeout) hoặc trả về mã lỗi thất bại.
   - Một hoặc nhiều Deployment cốt lõi (`frontend`, `frontend-proxy`, `checkout`, `payment`) không đạt trạng thái `Ready` sau khi hoàn tất lệnh deploy.
   - Kịch bản smoke test trả về kết quả thất bại.
   - Hệ thống giám sát (Grafana/Jaeger) ghi nhận tỷ lệ lỗi HTTP 5xx tăng vọt hoặc latency của các endpoint thanh toán/storefront vượt ngưỡng cho phép.
4. **Chuẩn hóa quy trình Rollback thủ công**:
   - Sử dụng lệnh rollback hạ tầng:
     ```sh
     helm rollback techx-corp <PREVIOUS_GOOD_REVISION> -n techx-corp --wait --timeout 10m
     ```
   - Chạy các lệnh kiểm tra rollout status để xác minh hạ tầng đã ổn định:
     ```sh
     kubectl -n techx-corp rollout status deploy/frontend-proxy --timeout=300s
     kubectl -n techx-corp rollout status deploy/frontend --timeout=300s
     kubectl -n techx-corp rollout status deploy/checkout --timeout=300s
     kubectl -n techx-corp rollout status deploy/payment --timeout=300s
     ```
   - Rerun smoke test để xác nhận dịch vụ storefront đã được khôi phục.

## Acceptance Criteria
- Cung cấp runbook hướng dẫn chi tiết quy trình deploy an toàn và quy trình xử lý sự cố/rollback cho operator.
- Lệnh deploy bắt buộc phải sử dụng các cờ kiểm soát an toàn hạ tầng (`--wait`, `--atomic`, `--timeout`, `--history-max`).
- Xác định rõ ràng các điều kiện cần kiểm tra trên AWS ALB (Target Group Health) và Kubernetes namespace.
- Operator có khả năng theo dõi tiến trình rollout của các Deployment quan trọng bằng lệnh `kubectl rollout status`.

## Kiểm thử / xác minh
1. **Kiểm thử Rollback tự động (Negative path)**: Thực hiện deploy chart với một tag image bị lỗi cố ý (ví dụ: tag không tồn tại). Kiểm tra xem Helm có tự động kích hoạt quá trình atomic rollback sau khi timeout hay không.
2. **Kiểm thử Rollback thủ công**:
   - Ghi nhận lịch sử: `helm history techx-corp -n techx-corp`.
   - Kích hoạt rollback thủ công về revision tốt trước đó: `helm rollback techx-corp <revision> -n techx-corp --wait`.
   - Xác nhận trạng thái rollout của các deployment quay trở về ổn định.

## Rủi ro & rollback
- **Rủi ro**: Lịch sử release bị dọn sạch hoặc số lượng history được lưu quá ngắn (`--history-max` quá nhỏ) khiến không tìm lại được revision tốt để rollback. Giới hạn lưu trữ tối thiểu nên để là 10.
- **Rollback**: Nếu lệnh rollback của Helm bị treo do lỗi kết nối hoặc cluster mất ổn định, operator sẽ phải can thiệp trực tiếp bằng cách kiểm tra các mô-đun controller hoặc cấu hình lại các service theo cách thủ công.

---

## English Summary
This backlog item covers the cluster and operator safety procedures for the REL-08 task in the `techx-corp-infra` repository. It defines standard EKS deployment practices using Helm parameters (`--wait --atomic --timeout 10m --history-max 10`), outlines pre-deployment checks (ALB Target Group Health, namespace status), documents the rollback runbook (`helm rollback`), and defines validation steps (`kubectl rollout status` and post-rollback smoke tests) to ensure safe cluster state operations.
