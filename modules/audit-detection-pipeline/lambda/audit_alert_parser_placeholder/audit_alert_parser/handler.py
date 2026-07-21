"""Placeholder Lambda handler for Mandate 11.2 infrastructure rollout.

Task 11.2 owns the AWS event pipeline. Task 11.3 owns the real parser code and
should replace this package through CI/CD after the infrastructure exists.
"""

from __future__ import annotations

import json
from typing import Any, Mapping


def lambda_handler(event: Mapping[str, Any], context: Any = None) -> dict[str, Any]:
    """Accept raw events without parsing so pipeline wiring can be validated."""

    source_type = _source_type(event)
    response = {
        "status": "placeholder_received",
        "source_type": source_type,
        "next_step": "Deploy Task 11.3 parser package to this Lambda function.",
    }
    print(json.dumps(response, sort_keys=True, separators=(",", ":")))
    return response


def _source_type(event: Mapping[str, Any]) -> str:
    detail = event.get("detail")
    if (
        event.get("detail-type") == "AWS API Call via CloudTrail"
        and isinstance(detail, Mapping)
    ):
        return "cloudtrail"

    awslogs = event.get("awslogs")
    if isinstance(awslogs, Mapping) and awslogs.get("data"):
        return "cloudwatch_logs"

    return "unknown"

