# Hướng dẫn sử dụng Terraform remote state cho TechX Corp Infra

Tài liệu này hướng dẫn cách khởi tạo, cấu hình, di chuyển và quản lý Terraform Remote State bằng Amazon S3 làm backend lưu trữ trạng thái tập trung và bảo mật cho TechX Corp Infrastructure.

---

## 1. Tổng quan (Overview)

Việc chuyển đổi từ lưu trữ trạng thái local (`terraform.tfstate`) sang Remote State Backend (S3) giúp:
- **Tập trung hóa:** Lưu trữ state file tại S3 bucket được mã hóa và phân quyền chặt chẽ.
- **Khóa trạng thái (State Locking):** Sử dụng tính năng S3 Native Locking (`use_lockfile = true` có từ Terraform 1.10+) để ngăn chặn việc chạy song song ghi đè làm hỏng state.
- **Bảo mật:** Mã hóa dữ liệu bằng KMS Customer Managed Key (CMK), bật chính sách thực thi TLS (HTTPS) và chặn truy cập công cộng.
- **Lịch sử & Phục hồi:** Bật tính năng Versioning để lưu giữ lịch sử các thay đổi trạng thái và khôi phục khi cần thiết.

---

## 2. Điều kiện trước khi chạy (Prerequisites)

Trước khi thực hiện các lệnh bên dưới, hãy đảm bảo:
1. Đã cài đặt **Terraform phiên bản >= 1.10.0** (Khuyến nghị sử dụng v1.15.7).
2. Đã cài đặt **AWS CLI** và cấu hình credentials hợp lệ có quyền quản trị tài nguyên S3, KMS, IAM (Ví dụ tài khoản IAM `hungxqt` trong tài khoản AWS `493499579600`).
3. Đang ở thư mục gốc của repository: `techx-corp-infra`.

---

## 3. Tạo S3 state bucket lần đầu (Bootstrap S3 state bucket)

Thực hiện bước này để tạo hạ tầng lưu trữ S3 Bucket và KMS Key phục vụ cho Remote State bằng local state trước.

1. **Chuẩn bị file cấu hình:**
   Đảm bảo cấu hình backend trong `bootstrap/provider.tf` tạm thời được comment lại (đã thực hiện):
   ```hcl
   # backend "s3" {}
   ```

2. **Khởi tạo thư mục bootstrap:**
   Chạy lệnh init với local backend để tải AWS provider:
   ```bash
   terraform -chdir=bootstrap init
   ```

3. **Tạo plan và kiểm tra:**
   Xuất file kế hoạch thực thi để review các tài nguyên sẽ được tạo (gồm 9 tài nguyên cơ sở bảo mật):
   ```bash
   # Dành cho Command Prompt / Bash
   terraform -chdir=bootstrap plan -out=bootstrap.tfplan
   
   # Dành cho PowerShell (được khuyến nghị để tránh xung đột tham số -out)
   terraform -chdir=bootstrap plan "-out=bootstrap.tfplan"
   ```

4. **Áp dụng (Apply) plan:**
   Tiến hành tạo tài nguyên thực tế trên AWS:
   ```bash
   terraform -chdir=bootstrap apply "bootstrap.tfplan"
   ```

---

## 4. Chuyển bootstrap sang remote state (Migrate bootstrap state)

Sau khi tạo xong S3 bucket, chúng ta chuyển chính state file của thư mục `bootstrap` lên S3 để quản lý tập trung.

1. **Tạo cấu hình backend:**
   Tạo file `bootstrap/backend.hcl` (không commit file này lên Git) từ các output của bước apply trước.
   Nội dung mẫu:
   ```hcl
   bucket       = "techx-tf-state-493499579600-us-east-1"
   key          = "bootstrap/terraform.tfstate"
   region       = "us-east-1"
   encrypt      = true
   use_lockfile = true
   ```

2. **Kích hoạt block backend:**
   Mở file `bootstrap/provider.tf` và bỏ comment block backend:
   ```hcl
   backend "s3" {}
   ```

3. **Di chuyển state lên S3:**
   Chạy lệnh init với tham số di chuyển trạng thái tự động:
   ```bash
   # Dành cho Command Prompt / Bash
   terraform -chdir=bootstrap init -migrate-state -force-copy -backend-config=backend.hcl
   
   # Dành cho PowerShell
   terraform -chdir=bootstrap init "-migrate-state" "-force-copy" "-backend-config=backend.hcl"
   ```

4. **Xác minh di chuyển thành công:**
   Liệt kê danh sách tài nguyên trong remote state để chắc chắn state đã được đẩy lên S3:
   ```bash
   terraform -chdir=bootstrap state list
   ```
   Bạn cũng có thể xóa file `bootstrap/terraform.tfstate` cục bộ sau khi đã xác minh thành công.

---

## 5. Cấu hình production dùng remote state (Configure production backend)

1. **Tạo cấu hình backend cho production:**
   Tạo file `enviroments/production/backend.hcl` (không commit file này lên Git) với nội dung chỉ định key riêng biệt cho môi trường production:
   ```hcl
   bucket       = "techx-tf-state-493499579600-us-east-1"
   key          = "production/terraform.tfstate"
   region       = "us-east-1"
   encrypt      = true
   use_lockfile = true
   ```

2. **Cấu hình provider:**
   Đảm bảo `enviroments/production/provider.tf` có cấu hình backend trống như sau:
   ```hcl
   backend "s3" {
     key          = "production/terraform.tfstate"
     encrypt      = true
     use_lockfile = true
   }
   ```

3. **Khởi tạo backend cho production:**
   Khởi tạo môi trường production để trỏ vào S3 remote backend:
   ```bash
   # Dành cho Command Prompt / Bash
   terraform -chdir=enviroments/production init -backend-config=backend.hcl
   
   # Dành cho PowerShell
   terraform -chdir=enviroments/production init "-backend-config=backend.hcl"
   ```

---

## 6. Lệnh kiểm tra (Validation & drift checks)

### Kiểm tra cú pháp và định dạng (Static Checks)
Định kỳ chạy các lệnh kiểm tra lỗi cú pháp và kiểm tra chuẩn định dạng:
```bash
# Định dạng code
terraform -chdir=bootstrap fmt -check
terraform -chdir=enviroments/production fmt -check

# Xác thực tính hợp lệ của cấu hình
terraform -chdir=bootstrap validate
terraform -chdir=enviroments/production validate
```

### Kiểm tra độ lệch trạng thái (Drift Checks)
Để kiểm tra xem hạ tầng thực tế trên cloud có bị thay đổi ngoài tầm kiểm soát của Terraform (hành vi drift) hay không:
```bash
terraform -chdir=enviroments/production plan
```
Lệnh này sẽ đối chiếu mã Terraform hiện tại với trạng thái thực tế ghi nhận trên AWS mà không thực hiện bất kỳ thay đổi nào.

---

## 7. Khôi phục và rollback (Rollback and recovery)

Trường hợp xảy ra sự cố lỗi hoặc mất mát dữ liệu trạng thái (State Corruption / Lock Failure):

### Phục hồi state bị lỗi bằng S3 Versioning:
Vì S3 Bucket đã bật tính năng Versioning, bạn luôn có thể tải lại các phiên bản state cũ:
1. Truy cập vào AWS Console S3 hoặc sử dụng CLI để kiểm tra các phiên bản cũ của file `production/terraform.tfstate`:
   ```bash
   aws s3api list-object-versions --bucket techx-tf-state-493499579600-us-east-1 --prefix production/terraform.tfstate
   ```
2. Tải về phiên bản trạng thái trước khi bị lỗi (`<version-id>`):
   ```bash
   aws s3api get-object --bucket techx-tf-state-493499579600-us-east-1 --key production/terraform.tfstate --version-id <version-id> restored_state.tfstate
   ```
3. Sau khi xác thực nội dung file `restored_state.tfstate` đã khôi phục chuẩn xác, tải đè phiên bản này lên S3:
   ```bash
   terraform -chdir=enviroments/production state push restored_state.tfstate
   ```

### Xử lý kẹt Lock (Force Unlock):
Nếu hệ thống CI/CD bị ngắt đột ngột và lock file vẫn bị giữ, chạy lệnh sau để giải phóng lock sau khi đã chắc chắn không có tiến trình nào khác đang áp dụng hạ tầng:
```bash
terraform -chdir=enviroments/production force-unlock <lock-id>
```

---

## 8. Quy tắc an toàn (Safety rules)

> [!CAUTION]
> **1. KHÔNG COMMIT file trạng thái cục bộ (`.tfstate`)**
> File Terraform State chứa các dữ liệu cực kỳ nhạy cảm (như mật khẩu, khóa bí mật, thông tin tài nguyên nội bộ dưới dạng cleartext). Đảm bảo `.gitignore` đã chặn mọi file `*.tfstate`, `*.tfstate.backup`, và các file cấu hình backend cụ thể như `backend.hcl`.

> [!WARNING]
> **2. KHÔNG CHẠY apply trực tiếp cho môi trường Production mà không thông qua Plan Review**
> Mọi thay đổi trên production bắt buộc phải được tạo plan trước (`terraform plan "-out=prod.tfplan"`), lưu trữ plan đó dưới dạng một artifact được kiểm tra và review bởi các bên liên quan, sau đó áp dụng chính xác plan đó thông qua lệnh `terraform apply "prod.tfplan"`. Tuyệt đối không chạy `terraform apply` thô trực tiếp không chỉ định plan file trên production.

> [!IMPORTANT]
> **3. KHÔNG TỰ Ý XÓA S3 State Bucket**
> S3 State Bucket được thiết lập chính sách `prevent_destroy = true` trong vòng đời Terraform để ngăn việc vô tình xóa. Mọi yêu cầu gỡ bỏ hoặc thay thế bucket cần được thảo luận kỹ lưỡng và thực hiện tuần tự để tránh mất toàn bộ dữ liệu quản lý hạ tầng.
