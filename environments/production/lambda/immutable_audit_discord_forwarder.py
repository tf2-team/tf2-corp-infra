import json
import os
import time
import urllib.error
import urllib.request

import boto3


secretsmanager = boto3.client("secretsmanager")
_webhook_url = None
USER_AGENT = "TechX-Mandate12-Audit-Discord-Forwarder/1.0"


def _get_webhook_url():
    global _webhook_url
    if _webhook_url:
        return _webhook_url

    secret_arn = os.environ["DISCORD_WEBHOOK_SECRET_ARN"]
    response = secretsmanager.get_secret_value(SecretId=secret_arn)
    _webhook_url = response["SecretString"].strip()
    return _webhook_url


def _short(value, limit=900):
    text = json.dumps(value, default=str) if not isinstance(value, str) else value
    return text if len(text) <= limit else f"{text[:limit - 3]}..."


def _format_message(event):
    detail = event.get("detail", {})
    actor = detail.get("userIdentity", {}).get("arn") or detail.get("userIdentity", {}).get("principalId") or "unknown"
    action = detail.get("eventName", "unknown")
    source = detail.get("eventSource", event.get("source", "unknown"))
    event_time = detail.get("eventTime", event.get("time", "unknown"))
    source_ip = detail.get("sourceIPAddress", "unknown")
    region = detail.get("awsRegion", event.get("region", "unknown"))
    request_id = detail.get("requestID", "unknown")
    event_id = detail.get("eventID", event.get("id", "unknown"))

    title = f"Audit tamper attempt: {action}"
    fields = [
        {"name": "Actor", "value": _short(actor, 1024), "inline": False},
        {"name": "Source", "value": _short(source, 256), "inline": True},
        {"name": "Region", "value": _short(region, 256), "inline": True},
        {"name": "Source IP", "value": _short(source_ip, 256), "inline": True},
        {"name": "Event time", "value": _short(event_time, 256), "inline": True},
        {"name": "Event ID", "value": _short(event_id, 256), "inline": False},
        {"name": "Request ID", "value": _short(request_id, 256), "inline": False},
    ]

    request_parameters = detail.get("requestParameters")
    if request_parameters:
        fields.append({"name": "Request parameters", "value": f"```json\n{_short(request_parameters, 900)}\n```", "inline": False})

    return {
        "username": "TechX Audit",
        "embeds": [
            {
                "title": title,
                "description": "Mandate 12 audit anti-defeat control matched a CloudTrail event.",
                "color": 15158332,
                "fields": fields,
            }
        ],
    }


def _post_discord(payload):
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        _get_webhook_url(),
        data=body,
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=4) as response:
            response.read()
    except urllib.error.HTTPError as exc:
        error_body = ""
        try:
            error_body = exc.read().decode("utf-8")[:500]
        except Exception:
            pass
        if exc.code == 429:
            retry_after = 1
            try:
                retry_after = json.loads(error_body).get("retry_after", 1)
            except Exception:
                pass
            time.sleep(min(float(retry_after), 5))
        print(json.dumps({
            "level": "error",
            "message": "discord_http_error",
            "status": exc.code,
            "reason": exc.reason,
            "body": error_body,
        }))
        raise


def handler(event, _context):
    failures = []
    for record in event.get("Records", []):
        try:
            cloudtrail_event = json.loads(record["body"])
            _post_discord(_format_message(cloudtrail_event))
        except Exception as exc:
            print(json.dumps({"level": "error", "message": "discord_delivery_failed", "error": str(exc)}))
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}
