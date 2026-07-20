"""Placeholder Lambda handler for the Mandate 11.4 Discord router.

Terraform owns the Lambda shell, SQS event source, IAM, log group, and alarms.
The real router package is deployed by the platform CI/CD workflow after the
infrastructure exists. This placeholder deliberately returns partial failures
for every SQS record so audit alerts are retried and eventually held in the DLQ
instead of being silently acknowledged before the real router is installed.
"""

from __future__ import annotations

import json
from typing import Any, Mapping


def lambda_handler(event: Mapping[str, Any], context: Any = None) -> dict[str, Any]:
    failures = [
        {"itemIdentifier": str(record.get("messageId", "unknown"))}
        for record in event.get("Records", [])
        if isinstance(record, Mapping)
    ]
    print(
        json.dumps(
            {
                "status": "placeholder_router_received",
                "failure_count": len(failures),
                "next_step": "Deploy the Task 11.4 audit_alert_router package through platform CI/CD.",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return {"batchItemFailures": failures}
