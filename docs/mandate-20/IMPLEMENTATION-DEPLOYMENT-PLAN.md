# Directive #20 - Ke hoach hoan thien ha tang va trien khai

**Ngay cap nhat:** 22/07/2026

**Pham vi:** Backup/recovery infrastructure va luong DynamoDB outbox -> MSK -> RDS -> persistence ACK.

**Chua bao gom:** Restore drill chinh thuc, integrity proof va ket qua RTO thuc te.

## 1. Trang thai hien tai

| Hang muc | Trang thai | Bang chung/Ghi chu |
|---|---|---|
| RDS automated backup/PITR | Da cau hinh live | Retention: RDS chinh 7 ngay, Mem0 14 ngay; encryption va deletion protection bat |
| DynamoDB PITR | Da cau hinh live | Continuous backup/PITR 35 ngay, ma hoa KMS |
| AWS Backup vault | Da cau hinh live | Vault Lock va recovery point cho RDS/DynamoDB |
| EBS backup plan hang gio | Da tao plan | Chua co volume duoc tag dung selector, chua co EBS recovery point |
| EBS encryption by default | Chua dat | Tai khoan hien chua bat; cac PVC volume dang ton tai chua ma hoa |
| Inventory money path | Mot phan | Da kiem RDS, DynamoDB, Valkey va EBS/PVC; can chot owner va phan loai volume con su dung |
| Topic `orders-persisted` | Chua live | Phai tao truoc khi deploy consumer/producer su dung ACK |
| Accounting persistence ACK | Da co thay doi code, chua deploy | Chi ACK sau khi transaction RDS thanh cong |
| Stale published-event reconciler | Da co thay doi code/IAM, chua deploy | Requeue event `published` qua han de replay khi MSK mat message hoac retention het |
| ADR RPO/RTO va runbook | Da cap nhat local | Can review, merge va ky ten |
| Restore drill tach biet | Chua chay | Se chay sau khi infrastructure gate dat PASS |

## 2. Thu tu trien khai

### Phase 1 - Validate va merge code

- Chay `terraform fmt -check`, `terraform validate` va review plan.
- Validate chart/manifests cho Checkout va Accounting.
- Merge cac thay doi ADR, IAM reconciler va luong persistence ACK.

### Phase 2 - Tao topic persistence ACK

- Tao topic `orders-persisted` tren MSK truoc khi deploy workload moi.
- Dat partition, replication factor, retention va ACL theo convention cua cum.
- Xac minh producer Accounting va consumer Checkout co quyen dung topic.
- Luu output lenh describe topic lam bang chung.

### Phase 3 - Apply infrastructure

- Apply Terraform de tao IRSA/IAM cho Accounting reconciler.
- Gan role ARN vao ServiceAccount `accounting`.
- Xac minh role chi co quyen `Query` va `UpdateItem` tren outbox table/index can thiet.
- Kiem tra lai RDS backup, DynamoDB PITR, vault lock va recovery points tren console.

### Phase 4 - Deploy Accounting truoc

- Deploy Accounting co transaction ghi RDS va publish `orders-persisted` sau khi commit.
- Bat stale-event reconciler voi threshold/cadence da cau hinh.
- Xac minh readiness, log, consumer lag va DB write thanh cong.

### Phase 5 - Deploy Checkout

- Deploy Checkout publisher theo co che chi chuyen event sang `published` sau MSK ACK.
- Bat consumer `orders-persisted` de xoa/ACK outbox chi sau persistence ACK.
- Xac minh retry idempotent va khong xoa event ngay sau publish `orders`.

### Phase 6 - Smoke test end-to-end

1. Tao mot order co correlation ID rieng.
2. Xac minh outbox: `pending` -> `published`.
3. Xac minh message den MSK va row duoc commit vao RDS.
4. Xac minh Accounting publish `orders-persisted`.
5. Xac minh Checkout ACK/xoa event trong DynamoDB.
6. Tam dung Accounting trong moi truong test, tao order, sau do bat lai va xac minh replay khong tao duplicate.

## 3. Hoan thien EBS/PVC backup

- Phan loai sau PVC-bound EBS volume: active, orphan hay disposable.
- Gan tag backup selector cho moi volume stateful can bao ve.
- Tao recovery point thu cong dau tien, sau do xac minh plan hang gio tao recovery point tu dong.
- Bat EBS encryption by default cho volume moi.
- Lap ke hoach migrate/recreate cac volume active chua ma hoa; khong thay truc tiep tren production.
- Xoa volume orphan chi sau khi owner xac nhan va da co snapshot neu can giu du lieu.

## 4. Infrastructure gate truoc restore drill

Chi bat dau drill khi tat ca dieu kien sau dat PASS:

- RPO/RTO tung store duoc ADR cam ket va owner ky ten.
- RDS PITR, DynamoDB PITR, EBS recovery point va vault retention co bang chung.
- Backup ma hoa at-rest va quyen xoa backup duoc tach khoi operator thong thuong.
- Topic `orders-persisted` va luong persistence ACK chay end-to-end.
- Stale-event reconciler replay duoc event `published` qua han.
- Co tai khoan/VPC/subnet/namespace tach biet cho restore target.
- Mentor da thong nhat thoi gian quan sat drill hoac quay video.

## 5. Ke hoach restore drill rieng

1. Ghi test dataset va luu checksum/count/timestamp lam baseline.
2. Gay mat/hong du lieu co kiem soat trong test scope.
3. Bat dau dong ho RTO.
4. PITR store ve thoi diem ngay truoc su co vao moi truong tach biet.
5. Dung app/read-only verifier ket noi restore target, khong tro production traffic sang do.
6. So sanh primary key, count, checksum va business invariant voi baseline.
7. Dung dong ho khi du lieu duoc xac minh va dich vu restore target san sang.
8. Ghi RPO thuc te, RTO thuc te, log/console evidence, sai lech va action item.

## 6. Tracking

| Buoc | Owner | Trang thai | Bang chung bat buoc |
|---|---|---|---|
| Review/merge ADR va Terraform | CDO/Infra | Dang cho | PR da approve va merge |
| Tao `orders-persisted` | Platform | Chua lam | Topic describe + ACL |
| Apply IAM reconciler | Infra | Chua lam | Terraform output + role policy |
| Deploy Accounting | App team | Chua lam | Rollout + logs + RDS row |
| Deploy Checkout | App team | Chua lam | Rollout + outbox lifecycle |
| Tag/snapshot EBS/PVC | CDO/Infra | Chua lam | Recovery point list |
| Smoke test persistence ACK | App/Platform | Chua lam | Correlation ID + DB/outbox evidence |
| Restore drill | TF + Mentor | Tach rieng, chua chay | Video/log + RPO/RTO + integrity proof |

## 7. Definition of done

Directive #20 chi duoc danh dau hoan thanh khi co mot lan restore that vao moi truong tach biet, du lieu sau restore dat integrity check, RPO/RTO thuc te khong vuot cam ket va mentor xem duoc toan bo bang chung. Viec merge PR hoac bat backup khong tu dong dong nghia directive da hoan thanh.
