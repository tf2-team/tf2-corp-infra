# Mandate 21 Person 1 Evidence Index (2026-07-28)

## 1. Directive 20 Status and Retained Targets

- **Sign-Off State:** Pending formal CDO and Mentor approval.
- **Retained Cost Items:** Formal RDS PostgreSQL restore instance (`techx-prod-tf2-postgres-restore`) and DynamoDB restore table (`techx-prod-tf2-orders-restore`) remain intact.
- **Data Protection Policy:** No snapshots, databases, tables, volumes, or payment records were deleted during this change.

## 2. Infrastructure Preflight Evidence

- **VPC Zonal NAT Routes:**
  - `priv-1a` -> `nat-1a` (`us-east-1a`)
  - `priv-1b` -> `nat-1b` (`us-east-1b`)
- **Terraform Invariant Validation:** Tested via `modules/vpc/tests/zonal_nat.tftest.hcl` (3/3 tests PASSED).

## 3. CloudTrail Cost Optimization Evidence

- **Previous Selector:** Basic management events (`IncludeManagementEvents=true`, `ReadWriteType=All`).
- **New Advanced Selectors:**
  1. `ManagementWrites` (`eventCategory=Management`, `readOnly=false`)
  2. `RequiredSecretReads` (`eventCategory=Management`, `eventSource=secretsmanager.amazonaws.com`, `eventName=GetSecretValue`)
  3. `SensitiveS3Data` (`eventCategory=Data`, `resources.type=AWS::S3::Object`, 6 sensitive prefixes)
- **Unit Test Verification:** `environments/production/lambda/tests/test_immutable_audit_health_check.py` (5/5 tests PASSED).

## 4. Cost Gate Status

- **Baseline 7-Day Actual:** `$317.21 / week`
- **Normalized Weekly Run-Rate:** `$288.86 / week`
- **Cost Gate Result:** **PASS** (`$288.86 / week` <= `$300.00 / week`)

## 5. FIS Experiment Templates & Stop Alarms

- **Module Contract:** `mandate21_fis_contract` (schema version `1.0`)
- **Templates:** Bounded immutable templates for `us-east-1a` and `us-east-1b`.
- **Stop Alarms (Fail-Closed):**
  1. `${project_name}-storefront-healthy-hosts`
  2. `${project_name}-storefront-5xx-ratio`
  3. `${project_name}-accepted-order-durability-gap`
  4. `${project_name}-mandate12-immutable-audit-control-health`

<!-- Change trail: @hungxqt - 2026-07-28 - Created Mandate 21 evidence index and preflight baseline log. -->
