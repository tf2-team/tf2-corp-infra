# Mandate 11 Audit Detection Pipeline

This module creates the infrastructure side of Mandate 11. It performs coarse
11.2 filtering, forwards raw candidate events to the 11.3 parser Lambda, wires
11.3 alert-ready payloads to a 11.4 SQS-to-Discord router, and creates 11.5
CloudWatch TTD evidence monitoring.

## Responsibility Boundary

```text
11.2 = coarse filtering and raw event forwarding
11.3 = parse, normalize, match rules, assign severity, format alert context
11.4 = route alert-ready payloads to Discord
11.5 = measure time-to-detect from structured CloudWatch evidence
11.6 = allowlist/noise reduction after rule matching
```

The module intentionally does not parse CloudTrail policy documents, assign
severity, suppress Terraform/CI actors, or transform CloudWatch Logs
`awslogs.data`. Those decisions remain inside the platform parser code.

## Routes

```text
CloudTrail/EventBridge -> techx-audit-alert-parser
EKS CloudWatch Logs subscription -> techx-audit-alert-parser
techx-audit-alert-parser -> SQS alert-ready queue -> techx-audit-alert-router -> Discord
```

The Lambda packages created by this module are placeholders. Platform CI/CD
updates the same functions with the real code using handlers:

```text
audit_alert_parser.handler.lambda_handler
audit_alert_router.handler.lambda_handler
```

## Secret Handling

Do not put the Discord webhook value in Terraform variables, tfvars, state, PR
comments, or logs. When `discord_webhook_secret_arn` is empty, this module
creates only the Secrets Manager secret shell. The secret value should be written
manually in AWS Secrets Manager Console after Terraform creates the secret shell.
Use the output `audit_detection_discord_webhook_secret_arn` to find the exact
secret, then choose **Retrieve secret value** / **Edit** and store the webhook
URL as the secret value. Never paste the webhook value into Terraform, GitHub,
PR comments, or logs.

## Rollout Guardrail

Enable the router in a reviewed change after checking:

- EKS audit log group has subscription-filter capacity.
- Task 11.3 parser package is ready to deploy.
- Task 11.4 router package is ready to deploy.
- Discord webhook is stored in Secrets Manager through GitHub Actions.
- DLQ, alarm, and TTD dashboard ownership is agreed.
- Mentor test cases are scheduled.
