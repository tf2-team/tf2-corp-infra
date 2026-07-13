# Backlog: COS-01 (slice) — AWS Cost Anomaly Detection (IaC)

## Mapping

| Field | Value |
|---|---|
| **CDO-03 backlog** | **COS-01** — Cost Guardrails và Optimization |
| **TF2 ID** | **TF2-12** — Cost guardrails & optimization |
| **Trụ cột** | Cost Optimization |
| **Owner** | CDO-03 |
| **Priority** | P1 (cùng wave cost guardrails; sau / song song Budgets) |
| **Mandate** | `phase3/onboarding/BUDGET.md` — ~**$300 / tuần / TF**; cần phát hiện spike sớm |
| **Scope this slice** | **Cost Anomaly Detection only** (monitor SERVICE + email subscription). Budgets/SNS = slice riêng. |
| **Related ADR** | `docs/adr/cost-anomaly-detection-with-budgets.md` |

## Bối cảnh

AWS Budgets (slice COS-01 budgets) cảnh báo khi **chạm trần** (monthly $900 / daily $45). Budget **không** học baseline: chi phí nhảy bất thường trong ngày (NAT, EC2, data transfer, mentor/misconfig) có thể vẫn dưới % budget nhưng đã “lạ”.

AWS **Cost Anomaly Detection** (Cost Explorer) so sánh spend với pattern đã học và gửi alert khi impact vượt ngưỡng. Account đã có monitor Console tay (`Webapp-Group10-Services-Monitor`); repo chưa có module Terraform CAD — khó review/PR và dễ lệch env.

## Vấn đề

1. Không có CAD trong Terraform → guardrail spike không versioned.
2. Budgets alone không đủ cho “đột biến so với hôm qua / service X”.
3. CAD là **account-level**: wire dev + prod trên cùng account → trùng monitor/subscription.
4. Monitor Console Group10 (threshold $100 / 40%) có thể không khớp TF2 naming / ownership.

## Giải pháp đề xuất (slice này)

1. **Module `modules/cost-anomaly`**
   - `aws_ce_anomaly_monitor` — `DIMENSIONAL` / dimension **`SERVICE`**
   - `aws_ce_anomaly_subscription` — frequency **`DAILY`** (override được)
   - Subscriber **EMAIL** (`alert_email`)
   - Threshold expression **AND**:
     - `ANOMALY_TOTAL_IMPACT_ABSOLUTE` ≥ **$25** (default; capstone nhạy hơn $100 Group10)
     - `ANOMALY_TOTAL_IMPACT_PERCENTAGE` ≥ **40%**
   - `enabled` toggle; validation email khi enabled

2. **Wire production only**
   - `environments/production` → `module.cost_anomaly`
   - Variables/outputs/tfvars (`cost_anomaly_*`)
   - **Không** wire `environments/development`

3. **Operator**
   - Sau apply: Confirm email nếu AWS gửi confirmation
   - CAD **chỉ alert**, không hard-stop spend
   - Monitor Console Group10 có thể giữ hoặc xóa tay (ngoài state TF) để tránh 2 kênh spam

## Ngoài scope

| Item | Ghi chú |
|---|---|
| AWS Budgets + SNS | Slice `2026-07-13-cos-01-aws-cost-budgets` |
| CUSTOM monitor / linked account filters | Có thể mở rộng sau |
| SNS/Telegram cho CAD | CE subscription native EMAIL; multi-channel sau |
| NAT / node schedule / ECR | COS-01 còn lại |

## Acceptance Criteria

- [x] Module `cost-anomaly` tạo monitor + subscription khi `enabled=true`
- [x] Monitor type DIMENSIONAL / SERVICE
- [x] Threshold AND: absolute USD + percentage (tfvars override)
- [x] Production wire only; development không tạo CAD trùng account
- [x] `cost_anomaly_alert_email` validate khi enable
- [x] Outputs: monitor ARN, subscription ARN, operator note
- [x] Docs: backlog + change + ADR

## Kiểm thử / xác minh

```sh
terraform fmt -recursive modules/cost-anomaly environments/production

# Sau apply:
aws ce get-anomaly-monitors --query "AnomalyMonitors[?contains(MonitorName, 'anomaly')].[MonitorName,MonitorArn]"
aws ce get-anomaly-subscriptions --query "AnomalySubscriptions[?contains(SubscriptionName, 'anomaly')].[SubscriptionName,Subscribers]"
```

Manual:

1. Set `cost_anomaly_alert_email` trong production tfvars (đã: `ctran13904@gmail.com`).
2. Apply production (`module.cost_anomaly` hoặc full).
3. Billing → Cost Anomaly Detection: monitor `{project}-service-anomaly-monitor`.
4. Confirm email nếu có.

## Rủi ro & rollback

| Risk | Mitigation |
|---|---|
| 2 monitors (Group10 + TF) spam | Document; xóa/disable Group10 tay nếu không cần |
| Threshold thấp → noise | $25 + 40% AND; chỉnh tfvars |
| Threshold cao → miss spike | Hạ absolute trong tfvars |
| Email chưa confirm | Operator note |
| Trùng CAD nếu wire dev | Production only |
| CAD cần dữ liệu lịch sử | Early account days: ít anomaly; vẫn bật sớm |

**Rollback:** `cost_anomaly_enabled = false` + apply, hoặc `terraform destroy -target=module.cost_anomaly`.

## English Summary

Infra slice of **COS-01 / TF2-12**: Terraform **Cost Anomaly Detection** (SERVICE dimensional monitor + DAILY email subscription with AND thresholds $25 / 40%), **production only**. Complements AWS Budgets (ceiling) with baseline spike detection. Does not replace budgets or implement NAT/node/ECR items.
