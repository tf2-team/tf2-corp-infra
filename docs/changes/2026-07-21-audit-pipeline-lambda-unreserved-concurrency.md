# Change: Audit Pipeline Lambda Unreserved Concurrency

## Summary

Stop reserving fixed concurrent executions on the audit-pipeline parse and alert Lambdas so production Terraform apply no longer fails AWS Lambda's account unreserved-concurrency floor check.

## Context

Production apply failed with:

```text
InvalidParameterValueException: Specified ReservedConcurrentExecutions for function
decreases account's UnreservedConcurrentExecution below its minimum value of [10].
```

Both `techx-parse-lambda` and `techx-audit-alert-parser` requested `reserved_concurrent_executions = 5` (10 reserved total). AWS requires at least 10 concurrent executions remain unreserved in the account/region. This workload account already has other reserved or limited concurrency headroom, so the PutFunctionConcurrency calls were rejected.

The same constraint was already handled for Mandate 12 Discord health Lambdas and runtime-security-alerting by using the account unreserved pool (`-1` or optional null reserved concurrency).

## Before

* `modules/audit-pipeline/main.tf` hardcoded `reserved_concurrent_executions = 5` on both Lambdas.
* Apply failed while configuring concurrency for `module.audit_pipeline.aws_lambda_function.parse_lambda` and `alert_lambda`.

## After

* Both Lambdas use `var.lambda_reserved_concurrent_executions`, defaulting to `-1` (no reserved concurrency; share the account unreserved pool).
* Callers may set a positive reserved value later once regional quota headroom is confirmed.
* Checkov `CKV_AWS_115` is skipped on both resources with the quota-floor rationale.
* Module README documents the default and override guidance.

## Technical Design Decisions

* **Default `-1` instead of removing the argument** — matches `immutable_audit_discord_health.tf` and keeps concurrency explicit in Terraform state/API.
* **Module variable rather than only hardcoding** — allows a future raise without another code change once Service Quotas / headroom allow reservation.
* **No production module argument override** — the default is correct for the current account; no `environments/production/main.tf` change required.

Alternatives considered:

| Alternative | Why not |
|---|---|
| Keep reserved `1` each | Still fails if remaining unreserved would drop below 10; also weak isolation value. |
| Request Lambda concurrency quota increase first | Correct long-term option, but blocks apply and is operator/quota work outside this code fix. |
| Omit the attribute entirely | Provider/state behavior is less explicit than `-1` for “use unreserved pool.” |

## Implementation Details

1. Added `lambda_reserved_concurrent_executions` (default `-1`) to the audit-pipeline module variables.
2. Wired both `aws_lambda_function.parse_lambda` and `alert_lambda` to that variable.
3. Added inline comments and Checkov skips for `CKV_AWS_115`.
4. Updated module README concurrency notes.

## Files Changed

**Module:**
* `modules/audit-pipeline/main.tf` — Unreserved concurrency for parse/alert Lambdas; Checkov skip comments.
* `modules/audit-pipeline/variables.tf` — New reserved-concurrency variable defaulting to `-1`.
* `modules/audit-pipeline/README.md` — Documented default and override condition.

**Documentation:**
* `docs/changes/2026-07-21-audit-pipeline-lambda-unreserved-concurrency.md` — This change record.

## Dependencies and Cross-Repository Impact

None. Chart and platform repositories are unaffected. No image or GitOps values change.

## Impact Analysis

| Dimension | Impact |
|---|---|
| **Application behavior** | Parse/alert Lambdas still run; they no longer reserve 5 concurrent executions each and share the account unreserved pool |
| **Infrastructure** | Removes failed PutFunctionConcurrency configuration; functions use unreserved concurrency |
| **Deployment** | Production Terraform apply for `module.audit_pipeline` should proceed past the concurrency step |
| **Performance** | No dedicated concurrency guarantee under multi-tenant Lambda load; acceptable for low-volume audit path |
| **Security** | No IAM or data-plane security change; isolation via reserved concurrency deferred until quota allows |
| **Reliability** | Apply unblocked; runtime may share concurrency with other functions in the account |
| **Cost** | No material cost change |
| **Backward compatibility** | Fully compatible for new creates; existing failed applies can be re-run |
| **Observability** | No change |

## Validation

### Automated Checks

| Check | Command / Tool | Result |
|---|---|---|
| Static review | Diff against hard-coded `5` and existing account-floor pattern | ✅ Matches Discord health / runtime-security approach |

### Manual Verification

* Confirmed error text matches reserved concurrency reducing unreserved pool below 10.
* Confirmed production module call does not pass a reserved override, so default `-1` applies.

### Remaining Verification (Post-Merge)

1. Re-run production Terraform plan/apply for the audit-pipeline module path.
2. Confirm `aws_lambda_function.parse_lambda` and `alert_lambda` create/update without PutFunctionConcurrency errors.
3. Optional: after apply,

```cmd
aws lambda get-function-concurrency --function-name techx-parse-lambda
aws lambda get-function-concurrency --function-name techx-audit-alert-parser
```

Expect no reserved concurrency (or reserved concurrent executions unset / -1 behavior).

## Migration or Deployment Notes

1. No pre-deployment AWS quota change required for this fix.
2. Re-run the failed production apply (or plan then apply) through the normal Terraform CI/promote path.
3. If reserved concurrency is desired later:

```hcl
module "audit_pipeline" {
  # ...
  lambda_reserved_concurrent_executions = 2
}
```

Only set a positive value after verifying account unreserved capacity remains ≥ 10.

## Risks and Rollback

| Risk | Likelihood | Severity | Mitigation / Rollback |
|---|---|---|---|
| Audit Lambdas compete for account concurrency under burst | Low | Low | Volume is filter/alert path; raise Service Quotas and set reserved concurrency later |
| Apply still fails for unrelated audit-pipeline issues | Medium | Medium | Inspect next apply error independently of concurrency |

**Rollback procedure:**

1. Revert this change in `modules/audit-pipeline/`.
2. Restore `reserved_concurrent_executions = 5` only after increasing Lambda concurrent executions quota / freeing reserved concurrency elsewhere so unreserved remains ≥ 10.

<!-- Change trail: @hungxqt - 2026-07-21 - Recorded audit-pipeline Lambda unreserved concurrency fix for apply failures. -->
