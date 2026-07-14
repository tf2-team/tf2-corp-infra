# Backlog: COS-01 (slice) — AWS Cost Budgets + SNS email-json guardrails

## Mapping

| Field | Value |
|---|---|
| **CDO-03 backlog** | **COS-01** — Cost Guardrails và Optimization (Budgets, NAT, Nodes) |
| **TF2 ID** | **TF2-12** — Cost guardrails & optimization (Budget $300, NAT, schedule, ECR) |
| **Trụ cột** | Cost Optimization |
| **Owner** | CDO-03 |
| **Priority** | P1 (guardrail Budget làm sớm trong wave cost) |
| **Mandate** | `phase3/onboarding/BUDGET.md` — ~**$300 / tuần / TF** |
| **Scope this slice** | **AWS Budgets + SNS only** (production account-level). NAT / node schedule / ECR lifecycle are **out of this change** (remain on COS-01 backlog). |
| **API note** | AWS Budgets **`time_unit` has no WEEKLY** — only DAILY / MONTHLY / QUARTERLY / ANNUALLY. Capstone ~$300/week × **3 weeks** → **monthly $900**. Daily **$45** ≈ 300/7. |

## Bối cảnh

TechX cấp mỗi TF trần **~$300/tuần** cho toàn bộ hạ tầng AWS. BTC và `docs/BACKLOG_CDO_03.md` (COS-01) yêu cầu dựng **AWS Budgets + alert** sớm để không vượt trần bất ngờ. Repo `techx-corp-infra` chưa có resource Terraform cho Budgets/SNS cost alerts; theo dõi chỉ bằng Cost Explorer thủ công.

## Vấn đề

1. Không có AWS Budget weekly/daily gắn trần $300/tuần.
2. Không có SNS topic + subscription để nhận cảnh báo (actual / forecasted).
3. Không có guardrail IaC — mỗi env/account dễ quên cấu hình Console tay, khó review/PR.
4. Budget là **account-level**: nếu wire cả dev + prod trên cùng account sẽ **trùng budget**; cần chỉ production (hoặc một stack duy nhất).

## Giải pháp đề xuất (slice này)

1. **Module `modules/cost-budgets`**
   - SNS topic `{name_prefix}-cost-alerts`
   - Topic policy cho phép `budgets.amazonaws.com` Publish (scoped SourceAccount / SourceArn)
   - Subscription protocol **`email-json`** (structured payload) tới `alert_email`
   - **Monthly** COST budget default **$900** (`time_unit = MONTHLY`) — map ~$300/week × 3 weeks; ACTUAL 50/80/100% + FORECASTED 100%
   - **Daily** COST budget default **$45** — ACTUAL 80% / 100% (early spike)
   - `time_period_start` mặc định **2026-07-13_00:00** (ngày bắt đầu giữ hệ thống trên AWS / deploy day)
   - `enabled` toggle; validation email khi enabled

2. **Wire production only**
   - `environments/production` → `module.cost_budgets`
   - Variables/outputs/tfvars; **không** wire `environments/development`

3. **Operator**
   - Sau apply: **Confirm** SNS email-json subscription trong inbox
   - Budgets **chỉ alert**, không hard-stop spend

## Ngoài scope (vẫn thuộc COS-01 / TF2-12, làm sau)

| Item | Ghi chú |
|---|---|
| NAT 2→1 / NAT Instance | VPC topology; trade HA |
| Schedule scale node group ngoài giờ | **Chỉ dev/test** — không production storefront 24/7 |
| ECR lifecycle keep-N | Đã có một phần lifecycle trên ECR module; review/tighten riêng |
| Cost Anomaly Detection | Slice riêng: `2026-07-13-cos-01-cost-anomaly-detection.md` + ADR `docs/adr/cost-anomaly-detection-with-budgets.md` |
| Client VPN schedule off | Vận hành / tfvars session — không nằm trong module budgets |

## Acceptance Criteria

- [ ] Module `cost-budgets` tạo SNS + monthly (+ optional daily) budgets khi `enabled=true`
- [ ] SNS subscription protocol = **`email-json`**
- [ ] Monthly limit mặc định **900 USD**; daily **45 USD** (có thể override tfvars)
- [ ] `time_unit` chỉ dùng giá trị AWS hỗ trợ (**MONTHLY** / **DAILY** — không WEEKLY)
- [ ] Notifications: monthly ACTUAL 50/80/100 + FORECASTED 100; daily ACTUAL 80/100
- [ ] Production wire only; development **không** tạo budget trùng account
- [ ] `cost_budgets_alert_email` bắt buộc khi enable (validation)
- [ ] Topic policy cho Budgets publish
- [ ] Outputs: topic ARN, budget names, operator note (confirm email)
- [ ] Docs: backlog + change record trong `techx-corp-infra/docs/`

## Kiểm thử / xác minh

```sh
terraform fmt -recursive modules/cost-budgets environments/production
terraform -chdir=environments/production init -backend=false
terraform -chdir=environments/production validate

# Sau apply (với email thật trong tfvars):
aws sns list-subscriptions-by-topic --topic-arn <topic-arn>
aws budgets describe-budgets --account-id <account-id> \
  --query "Budgets[?contains(BudgetName, 'monthly') || contains(BudgetName, 'daily')].[BudgetName,BudgetLimit,TimeUnit]"
```

Manual:

1. Set `cost_budgets_alert_email` trong production tfvars.
2. Apply production.
3. Confirm SNS email-json.
4. Billing → Budgets: thấy monthly $900 + daily $45.

## Rủi ro & rollback

| Risk | Mitigation |
|---|---|
| Email chưa Confirm → không nhận alert | Operator note + checklist post-apply |
| Budget spam (daily 50%) | Daily chỉ 80/100% |
| Trùng budget dev+prod | Production only |
| Tưởng budget “chặn chi” | Document: alert only; cắt resource thủ công |
| `time_period_start` thay đổi mỗi apply nếu dùng timestamp() | Fixed deploy-day string |

**Rollback:** `cost_budgets_enabled = false` + apply → xóa SNS/budgets module resources.

## English Summary

Infra slice of **COS-01 / TF2-12**: Terraform module for AWS Cost Budgets (**monthly $900** ≈ $300/week × 3, optional **daily $45**) and SNS **email-json** alerts, wired on **production only**. AWS Budgets has no WEEKLY period. Does not implement NAT/node schedule/ECR items of the full cost backlog. Operators must confirm the SNS subscription after apply; budgets warn but do not stop spend.
