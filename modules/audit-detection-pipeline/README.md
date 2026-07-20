# Mandate 11.2 Audit Detection Pipeline

This module creates the infrastructure side of Mandate 11.2. It performs only coarse filtering and forwards raw candidate events to the Task 11.3 parser Lambda.

## Responsibility Boundary

```text
11.2 = coarse filtering and raw event forwarding
11.3 = parse, normalize, match rules, assign severity, format alert context
11.6 = allowlist/noise reduction after rule matching
```

The module intentionally does not parse CloudTrail policy documents, assign severity, suppress Terraform/CI actors, or transform CloudWatch Logs `awslogs.data`.

## Routes

```text
CloudTrail/EventBridge -> techx-audit-alert-parser
EKS CloudWatch Logs subscription -> techx-audit-alert-parser
```

The Lambda package created by this module is only a placeholder. Task 11.3 CI/CD should update the same function with the real parser code using handler:

```text
audit_alert_parser.handler.lambda_handler
```

## Rollout Guardrail

Wire this module with `enabled = false` first. Enable it in a separate reviewed change after checking:

- EKS audit log group has subscription-filter capacity.
- Task 11.3 parser package is ready to deploy.
- DLQ and alarm ownership is agreed.
- Mentor test cases are scheduled.

