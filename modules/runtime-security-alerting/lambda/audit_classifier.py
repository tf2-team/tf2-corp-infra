import base64
import gzip
import hashlib
import json
import os
from datetime import datetime, timezone

import boto3


SNS_TOPIC_ARN = os.environ["RUNTIME_SNS_TOPIC_ARN"]
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "unknown")
DEDUPE_WINDOW_SECONDS = int(os.environ.get("DEDUPE_WINDOW_SECONDS", "300"))
VAP_POLICY_NAMES = set(json.loads(os.environ.get("VAP_POLICY_NAMES_JSON", "[]")))

sns = boto3.client("sns")
cloudwatch = boto3.client("cloudwatch")


def _decode_cloudwatch_logs_event(event):
    payload = base64.b64decode(event["awslogs"]["data"])
    return json.loads(gzip.decompress(payload).decode("utf-8"))


def _audit_event_from_message(message):
    try:
        return json.loads(message)
    except json.JSONDecodeError:
        return None


def _denied_by_runtime_policy(audit_event):
    response_status = audit_event.get("responseStatus", {}) or {}
    if response_status.get("code", 0) < 400:
        return False

    text = " ".join(
        str(response_status.get(key, ""))
        for key in ["reason", "message", "status"]
    )
    annotations = audit_event.get("annotations", {}) or {}
    annotation_text = " ".join(str(v) for v in annotations.values())
    haystack = f"{text} {annotation_text}"

    if any(policy_name in haystack for policy_name in VAP_POLICY_NAMES):
        return True

    mandate_terms = [
        "runtime-hardening",
        "privileged",
        "privilege escalation",
        "host network",
        "host pid",
        "hostpath",
        "fixed tag",
        "latest",
        "requests and limits",
        "drop all capabilities",
        "run as non-root",
    ]
    lowered = haystack.lower()
    return any(term in lowered for term in mandate_terms)


def _safe_get(obj, path, default=None):
    cur = obj
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def _classify(audit_event):
    user = audit_event.get("user", {}) or {}
    object_ref = audit_event.get("objectRef", {}) or {}
    source_ips = audit_event.get("sourceIPs", []) or []
    response_status = audit_event.get("responseStatus", {}) or {}

    actor = user.get("username", "unknown")
    namespace = object_ref.get("namespace", "")
    kind = object_ref.get("resource", object_ref.get("apiGroup", "unknown"))
    name = object_ref.get("name", "")
    verb = audit_event.get("verb", "unknown")
    source_ip = source_ips[0] if source_ips else "unknown"
    reason = response_status.get("reason", "Denied")
    message = str(response_status.get("message", ""))[:600]
    policy_hint = next(
        (policy for policy in VAP_POLICY_NAMES if policy in message),
        "runtime-hardening",
    )

    dedupe_source = "|".join([actor, source_ip, namespace, kind, name, verb, policy_hint])
    dedupe_key = hashlib.sha256(dedupe_source.encode("utf-8")).hexdigest()[:16]

    return {
        "severity": "P2",
        "signalType": "vap-admission-deny",
        "cluster": CLUSTER_NAME,
        "eventTime": audit_event.get("requestReceivedTimestamp") or audit_event.get("stageTimestamp"),
        "actor": actor,
        "sourceIp": source_ip,
        "verb": verb,
        "namespace": namespace,
        "resource": kind,
        "name": name,
        "policy": policy_hint,
        "reason": reason,
        "message": message,
        "dedupeKey": dedupe_key,
        "dedupeWindowSeconds": DEDUPE_WINDOW_SECONDS,
        "auditId": audit_event.get("auditID"),
        "note": "Sanitized alert: request body, Secret data, tokens and authorization headers are intentionally omitted.",
    }


def _publish(alert):
    subject = f"[P2] Runtime hardening deny on {alert['cluster']}"
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject[:100],
        Message=json.dumps(alert, sort_keys=True, indent=2),
        MessageAttributes={
            "severity": {"DataType": "String", "StringValue": alert["severity"]},
            "signalType": {"DataType": "String", "StringValue": alert["signalType"]},
            "cluster": {"DataType": "String", "StringValue": alert["cluster"]},
        },
    )


def _put_metric(name, value):
    cloudwatch.put_metric_data(
        Namespace="TechX/RuntimeSecurity",
        MetricData=[
            {
                "MetricName": name,
                "Dimensions": [{"Name": "ClusterName", "Value": CLUSTER_NAME}],
                "Timestamp": datetime.now(timezone.utc),
                "Value": value,
                "Unit": "Count",
            }
        ],
    )


def handler(event, context):
    logs_payload = _decode_cloudwatch_logs_event(event)
    matched = 0
    processed = 0

    for log_event in logs_payload.get("logEvents", []):
        audit_event = _audit_event_from_message(log_event.get("message", ""))
        if not audit_event:
            continue

        processed += 1
        if not _denied_by_runtime_policy(audit_event):
            continue

        alert = _classify(audit_event)
        _publish(alert)
        matched += 1
        print(json.dumps({"event": "classified_runtime_security_event", "alert": alert}, sort_keys=True))

    _put_metric("ProcessedAuditLogBatches", 1)
    if matched:
        _put_metric("RuntimeHardeningDenies", matched)

    return {"processed": processed, "matched": matched}
