import json
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

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


def _parse_event_time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def _seconds_since(value):
    event_time = _parse_event_time(value)
    if not event_time:
        return None
    return max((datetime.now(timezone.utc) - event_time).total_seconds(), 0)


def _cloudtrail_actor(detail):
    identity = detail.get("userIdentity", {})
    return identity.get("arn") or identity.get("principalId") or identity.get("userName") or "unknown"


def _cloudtrail_severity(detail):
    source = detail.get("eventSource", "")
    action = detail.get("eventName", "")
    if source == "cloudtrail.amazonaws.com" or action in {"DeleteTrail", "StopLogging"}:
        return "critical"
    if source == "iam.amazonaws.com":
        return "high"
    return "medium"


def _severity_color(severity):
    return {
        "critical": 15158332,
        "high": 15105570,
        "medium": 15844367,
        "low": 3447003,
    }.get(str(severity).lower(), 9807270)


def _format_cloudtrail_message(event):
    detail = event.get("detail", {})
    actor = _cloudtrail_actor(detail)
    action = detail.get("eventName", "unknown")
    source = detail.get("eventSource", event.get("source", "unknown"))
    event_time = detail.get("eventTime", event.get("time", "unknown"))
    source_ip = detail.get("sourceIPAddress", "unknown")
    region = detail.get("awsRegion", event.get("region", "unknown"))
    request_id = detail.get("requestID", "unknown")
    event_id = detail.get("eventID", event.get("id", "unknown"))
    severity = _cloudtrail_severity(detail)

    fields = [
        {"name": "Severity", "value": _short(severity, 256), "inline": True},
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
        fields.append({
            "name": "Request parameters",
            "value": f"```json\n{_short(request_parameters, 900)}\n```",
            "inline": False,
        })

    return {
        "username": "TechX Audit",
        "embeds": [
            {
                "title": f"High-risk audit action: {action}",
                "description": "A CloudTrail high-risk audit event matched an audit detection rule.",
                "color": _severity_color(severity),
                "fields": fields,
            }
        ],
    }


def _format_k8s_message(alert):
    severity = alert.get("severity", "high")
    rule_id = alert.get("rule_id", "unknown")
    actor = alert.get("actor") or alert.get("username") or alert.get("user") or "unknown"
    action = alert.get("action") or alert.get("verb") or "unknown"
    namespace = alert.get("namespace") or alert.get("object_namespace") or "cluster-scope"
    resource = alert.get("resource") or alert.get("object_ref") or alert.get("object") or "unknown"
    source_ip = alert.get("source_ip") or alert.get("sourceIPs") or "unknown"
    event_time = alert.get("event_time") or alert.get("eventTime") or alert.get("timestamp") or "unknown"
    status = alert.get("status", "alert_ready")

    fields = [
        {"name": "Severity", "value": _short(severity, 256), "inline": True},
        {"name": "Rule", "value": _short(rule_id, 256), "inline": True},
        {"name": "Status", "value": _short(status, 256), "inline": True},
        {"name": "Actor", "value": _short(actor, 1024), "inline": False},
        {"name": "Action", "value": _short(action, 256), "inline": True},
        {"name": "Namespace", "value": _short(namespace, 256), "inline": True},
        {"name": "Resource", "value": _short(resource, 512), "inline": False},
        {"name": "Source IP", "value": _short(source_ip, 256), "inline": True},
        {"name": "Event time", "value": _short(event_time, 256), "inline": True},
    ]

    allowlist_id = alert.get("allowlist_id")
    if allowlist_id:
        fields.append({"name": "Allowlist", "value": _short(allowlist_id, 256), "inline": True})

    return {
        "username": "TechX Audit",
        "embeds": [
            {
                "title": f"K8s audit alert: {rule_id}",
                "description": "An EKS audit event matched a Mandate 11 detection rule.",
                "color": _severity_color(severity),
                "fields": fields,
            }
        ],
    }


def _normalized_alert(envelope):
    normalized = envelope.get("normalized_event")
    evidence = envelope.get("evidence", {})
    if not isinstance(normalized, dict) or not isinstance(evidence, dict):
        raise ValueError("invalid_audit_alert_ready_v1_contract")

    alert = dict(normalized)
    fallback_fields = {
        "rule_id": evidence.get("rule_id"),
        "severity": evidence.get("severity"),
        "actor": evidence.get("actor"),
        "action": evidence.get("action"),
        "namespace": evidence.get("namespace"),
        "resource": evidence.get("resource"),
        "source_ip": evidence.get("source_ip"),
        "event_time": evidence.get("event_time_utc"),
        "status": evidence.get("status"),
    }
    for key, value in fallback_fields.items():
        if not alert.get(key) and value is not None:
            alert[key] = value
    return alert


def _message_contract(event):
    if (
        event.get("schema_version") == "audit-alert-ready/v1"
        and event.get("event") == "audit_alert_ready"
        and isinstance(event.get("normalized_event"), dict)
    ):
        return "audit_alert_ready_v1"
    if event.get("detail-type") == "AWS API Call via CloudTrail" or event.get("detail", {}).get("eventName"):
        return "cloudtrail_eventbridge"
    if event.get("source") == "eks_audit" or event.get("rule_id") or event.get("event") == "audit_detection_evidence":
        return "k8s_normalized_alert"
    return "unknown"


def _format_message(event):
    contract = _message_contract(event)
    if contract == "audit_alert_ready_v1":
        return _format_k8s_message(_normalized_alert(event))
    if contract == "cloudtrail_eventbridge":
        return _format_cloudtrail_message(event)
    if contract == "k8s_normalized_alert":
        return _format_k8s_message(event)
    raise ValueError("unsupported_audit_alert_message_contract")


def _evidence_fields(event, contract):
    if contract == "audit_alert_ready_v1":
        evidence = event.get("evidence", {})
        normalized = _normalized_alert(event)
        event_time = (
            evidence.get("event_time_utc")
            or normalized.get("event_time_utc")
            or normalized.get("event_time")
        )
        return {
            "message_contract": contract,
            "schema_version": event.get("schema_version"),
            "rule_id": evidence.get("rule_id") or normalized.get("rule_id", "unknown"),
            "severity": evidence.get("severity") or normalized.get("severity", "unknown"),
            "actor": evidence.get("actor") or normalized.get("actor", "unknown"),
            "action": evidence.get("action") or normalized.get("action", "unknown"),
            "namespace": evidence.get("namespace") or normalized.get("namespace", "cluster-scope"),
            "resource": evidence.get("resource") or normalized.get("resource", "unknown"),
            "source_ip": evidence.get("source_ip") or normalized.get("source_ip", "unknown"),
            "event_time": event_time,
            "time_to_alert_ready_seconds": evidence.get("time_to_alert_ready_seconds"),
            "end_to_end_ttd_seconds": _seconds_since(event_time),
        }

    if contract == "cloudtrail_eventbridge":
        detail = event.get("detail", {})
        event_time = detail.get("eventTime", event.get("time"))
        return {
            "message_contract": contract,
            "rule_id": f"cloudtrail.{detail.get('eventSource', 'unknown')}.{detail.get('eventName', 'unknown')}",
            "severity": _cloudtrail_severity(detail),
            "actor": _cloudtrail_actor(detail),
            "action": detail.get("eventName", "unknown"),
            "source": detail.get("eventSource", event.get("source", "unknown")),
            "source_ip": detail.get("sourceIPAddress", "unknown"),
            "event_time": event_time,
            "end_to_end_ttd_seconds": _seconds_since(event_time),
        }

    event_time = event.get("event_time") or event.get("eventTime") or event.get("timestamp")
    return {
        "message_contract": contract,
        "rule_id": event.get("rule_id", "unknown"),
        "severity": event.get("severity", "unknown"),
        "actor": event.get("actor") or event.get("username") or event.get("user") or "unknown",
        "action": event.get("action") or event.get("verb") or "unknown",
        "namespace": event.get("namespace") or event.get("object_namespace") or "cluster-scope",
        "resource": event.get("resource") or event.get("object_ref") or event.get("object") or "unknown",
        "source_ip": event.get("source_ip") or event.get("sourceIPs") or "unknown",
        "event_time": event_time,
        "time_to_alert_ready_seconds": event.get("time_to_alert_ready_seconds"),
        "end_to_end_ttd_seconds": _seconds_since(event_time),
    }


def _emit_delivery_evidence(event, contract, delivery_status, error=None):
    evidence = {
        "event": "audit_detection_evidence",
        "level": "error" if error else "info",
        "status": "alert_sent" if delivery_status == "sent" else "alert_delivery_failed",
        "delivery_channel": "discord",
        "delivery_status": delivery_status,
    }
    evidence.update(_evidence_fields(event, contract))
    if error:
        evidence["error"] = str(error)
    print(json.dumps(evidence, default=str))


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
        audit_event = {}
        contract = "unknown"
        try:
            audit_event = json.loads(record["body"])
            contract = _message_contract(audit_event)
            _post_discord(_format_message(audit_event))
            _emit_delivery_evidence(audit_event, contract, "sent")
        except Exception as exc:
            if audit_event:
                _emit_delivery_evidence(audit_event, contract, "failed", exc)
            else:
                print(json.dumps({"level": "error", "message": "discord_delivery_failed", "error": str(exc)}))
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}


# Change trail: @hungxqt - 2026-07-30 - Accept the versioned audit-alert-ready/v1
# envelope emitted by the production parser while preserving legacy contracts.
