import base64
import datetime as dt
import gzip
import json
import os
import re
import urllib.parse
import urllib.request

import boto3


secretsmanager = boto3.client("secretsmanager")
iam = boto3.client("iam")

WEBHOOK_URL = None


def handler(event, _context):
    if "Records" in event:
        return handle_sqs(event["Records"])

    return process_payload(event)


def handle_sqs(records):
    posted = 0
    for record in records:
        try:
            payload = json.loads(record.get("body", "{}"))
        except json.JSONDecodeError as exc:
            print(json.dumps({"ignored": "invalid_sqs_json", "error": str(exc)}))
            continue
        posted += process_payload(payload)["posted"]
    return {"posted": posted}


def process_payload(event):
    if is_contract_payload(event):
        return {"posted": post_contract_payload(event)}

    alerts = []
    if event.get("detail-type") == "AWS API Call via CloudTrail":
        alert = classify_cloudtrail(event.get("detail", {}))
        if alert:
            alerts.append(alert)
    elif "awslogs" in event:
        alerts.extend(classify_cloudwatch_logs(event))
    else:
        print(json.dumps({"ignored": "unknown_event_shape", "keys": sorted(event.keys())}))

    for alert in alerts:
        post_discord(alert)

    return {"posted": len(alerts)}


def is_contract_payload(event):
    return isinstance(event, dict) and isinstance(event.get("alert_messages"), list)


def post_contract_payload(payload):
    messages = payload.get("alert_messages") or []
    evidence_records = payload.get("evidence_records") or []
    posted = 0
    for message_index, message in enumerate(messages):
        evidence = evidence_records[message_index] if message_index < len(evidence_records) else {}
        for chunk_index, chunk in enumerate(split_discord_text(str(message))):
            post_contract_discord(chunk, evidence, message_index, chunk_index)
            posted += 1
    return posted


def post_contract_discord(message, evidence, message_index, chunk_index):
    severity = str(evidence.get("severity", "high")).upper()
    body = {
        "username": "TechX Audit Alert Router",
        "content": f"{severity_icon(severity)} **{severity} audit alert**",
        "embeds": [
            {
                "title": f"{severity_icon(severity)} {severity} Audit Detection",
                "description": message[:4000],
                "color": severity_color(severity),
                "fields": contract_fields(evidence),
                "timestamp": now_iso(),
            }
        ],
        "allowed_mentions": {"parse": []},
    }
    try:
        send_discord(body)
        print_delivery_evidence(evidence, "sent", "success", message_index, chunk_index)
    except Exception as exc:
        print_delivery_evidence(evidence, "delivery_failed", "failed", message_index, chunk_index, str(exc))
        raise


def contract_fields(evidence):
    fields = []
    for name, key in [
        ("Rule", "rule_id"),
        ("Actor", "actor"),
        ("Action", "action"),
        ("Event time", "event_time_utc"),
        ("Alert ready", "alert_ready_time"),
    ]:
        value = evidence.get(key)
        if value:
            fields.append({"name": name, "value": code_block(value), "inline": name not in {"Actor"}})
    return fields


def print_delivery_evidence(evidence, status, delivery_status, message_index, chunk_index, error=None):
    record = {
        "schema_version": "audit-detection-evidence/v1",
        "event": "audit_detection_evidence",
        "status": status,
        "rule_id": evidence.get("rule_id", "unknown"),
        "alert_sent_time": now_iso(),
        "delivery_target": "discord",
        "delivery_status": delivery_status,
        "message_index": message_index,
    }
    if chunk_index:
        record["message_chunk_index"] = chunk_index
    if error:
        record["error"] = str(error)[:300]
    print(json.dumps(record, sort_keys=True))


def split_discord_text(value, limit=1800):
    if len(value) <= limit:
        return [value]
    chunks = []
    current = []
    current_len = 0
    for line in value.splitlines():
        line_len = len(line) + 1
        if current and current_len + line_len > limit:
            chunks.append("\n".join(current))
            current = []
            current_len = 0
        if line_len > limit:
            for start in range(0, len(line), limit):
                chunks.append(line[start : start + limit])
            continue
        current.append(line)
        current_len += line_len
    if current:
        chunks.append("\n".join(current))
    return chunks


def classify_cloudtrail(detail):
    event_source = detail.get("eventSource", "")
    event_name = detail.get("eventName", "")
    request = detail.get("requestParameters") or {}
    actor = deep_get(detail, "userIdentity.arn") or deep_get(detail, "userIdentity.userName") or "unknown"

    if is_allowed(actor, env_json("ALLOWED_AWS_PRINCIPAL_ARN_PATTERNS")) and event_name in {
        "CreateAccessKey",
        "CreateAccessEntry",
    }:
        return None

    base = cloudtrail_base(detail)

    if event_source == "cloudtrail.amazonaws.com" and event_name in {
        "StopLogging",
        "DeleteTrail",
        "UpdateTrail",
        "PutEventSelectors",
        "DeleteEventDataStore",
        "UpdateEventDataStore",
    }:
        return {**base, "severity": "CRITICAL", "rule": "cloudtrail-logging-weakened", "summary": "CloudTrail logging or event selection was changed."}

    if event_source == "iam.amazonaws.com":
        return classify_iam(detail, base)

    if event_source == "eks.amazonaws.com":
        if event_name == "CreateAccessEntry":
            return {**base, "severity": "CRITICAL", "rule": "eks-access-entry-created", "summary": "New EKS access entry created for an IAM principal."}
        if event_name == "AssociateAccessPolicy":
            policy_arn = str(request.get("policyArn", ""))
            access_scope = request.get("accessScope") or {}
            if "AmazonEKSClusterAdminPolicy" in policy_arn:
                return {**base, "severity": "CRITICAL", "rule": "eks-cluster-admin-associated", "summary": "EKS cluster-admin access policy associated."}
            if access_scope.get("type") == "cluster":
                return {**base, "severity": "HIGH", "rule": "eks-cluster-wide-access-associated", "summary": "EKS cluster-wide access policy associated."}
        if event_name == "UpdateClusterConfig" and disables_eks_audit_logging(request):
            return {**base, "severity": "CRITICAL", "rule": "eks-audit-logging-disabled", "summary": "EKS control-plane audit/API/authenticator logging was disabled or weakened."}

    return None


def classify_iam(detail, base):
    event_name = detail.get("eventName", "")
    request = detail.get("requestParameters") or {}

    if event_name == "CreateAccessKey":
        return {**base, "severity": "HIGH", "rule": "iam-access-key-created", "summary": "Long-lived IAM access key was created."}

    if event_name in {"AttachUserPolicy", "AttachRolePolicy", "AttachGroupPolicy"}:
        policy_arn = str(request.get("policyArn", ""))
        if "AdministratorAccess" in policy_arn:
            return {**base, "severity": "CRITICAL", "rule": "iam-admin-policy-attached", "summary": "AWS AdministratorAccess policy was attached."}
        if managed_policy_is_admin(policy_arn):
            return {**base, "severity": "CRITICAL", "rule": "iam-wildcard-policy-attached", "summary": "Managed policy with wildcard admin permissions was attached."}
        return None

    if event_name in {"PutUserPolicy", "PutRolePolicy", "PutGroupPolicy", "CreatePolicyVersion"}:
        policy_doc = parse_policy_doc(request.get("policyDocument"))
        if policy_is_admin(policy_doc):
            return {**base, "severity": "CRITICAL", "rule": "iam-inline-admin-policy-written", "summary": "Inline or managed policy version grants wildcard admin permissions."}
        return None

    if event_name == "SetDefaultPolicyVersion":
        policy_arn = str(request.get("policyArn", ""))
        version_id = str(request.get("versionId", ""))
        if "AdministratorAccess" in policy_arn or managed_policy_is_admin(policy_arn, version_id):
            return {**base, "severity": "CRITICAL", "rule": "iam-admin-policy-version-defaulted", "summary": "Default IAM policy version grants administrator permissions."}
        return None

    return None


def classify_cloudwatch_logs(event):
    payload = gzip.decompress(base64.b64decode(event["awslogs"]["data"]))
    data = json.loads(payload)
    alerts = []
    for item in data.get("logEvents", []):
        try:
            audit = json.loads(item.get("message", "{}"))
        except json.JSONDecodeError:
            continue
        alert = classify_kubernetes_audit(audit, item.get("timestamp"))
        if alert:
            alerts.append(alert)
    return alerts


def classify_kubernetes_audit(audit, timestamp_ms):
    verb = audit.get("verb", "")
    obj = audit.get("objectRef") or {}
    resource = obj.get("resource", "")
    subresource = obj.get("subresource", "")
    namespace = obj.get("namespace", "")
    user = deep_get(audit, "user.username") or "unknown"

    if is_allowed(user, env_json("ALLOWED_KUBERNETES_USER_PATTERNS")):
        return None

    base = kubernetes_base(audit, timestamp_ms)
    prod_namespace = namespace_matches(namespace)

    if verb in {"create", "update", "patch"} and resource in {"clusterrolebindings", "rolebindings"}:
        role_name = deep_get(audit, "requestObject.roleRef.name")
        if role_name == "cluster-admin":
            return {**base, "severity": "CRITICAL", "rule": "k8s-cluster-admin-binding", "summary": "Kubernetes binding to cluster-admin was created or changed."}

    if prod_namespace and resource == "secrets" and verb in {"get", "list", "watch"}:
        return {**base, "severity": "HIGH", "rule": "k8s-secret-read-unapproved", "summary": "Kubernetes Secret was read or listed by a non-allowlisted identity."}

    if prod_namespace and resource == "pods" and subresource == "exec" and verb == "create":
        return {**base, "severity": "HIGH", "rule": "k8s-prod-pod-exec", "summary": "Interactive exec into a production pod was requested."}

    if prod_namespace and verb in {"create", "update", "patch"} and resource in {"pods", "deployments", "statefulsets", "daemonsets", "jobs", "cronjobs"}:
        if request_has_privileged_workload(audit.get("requestObject")):
            return {**base, "severity": "CRITICAL", "rule": "k8s-privileged-workload", "summary": "Privileged workload or host-level access was created or changed."}

    if prod_namespace and verb in {"delete", "deletecollection"} and resource in {"deployments", "statefulsets", "daemonsets", "services", "ingresses", "configmaps", "secrets"}:
        return {**base, "severity": "HIGH", "rule": "k8s-prod-resource-delete", "summary": "Production Kubernetes resource was deleted."}

    return None


def cloudtrail_base(detail):
    event_time = detail.get("eventTime")
    detected_at = now_iso()
    return {
        "source": "AWS CloudTrail",
        "environment": os.environ.get("ENVIRONMENT", "production"),
        "cluster": os.environ.get("CLUSTER_NAME", ""),
        "actor": deep_get(detail, "userIdentity.arn") or deep_get(detail, "userIdentity.userName") or "unknown",
        "action": f"{detail.get('eventSource', 'unknown')} / {detail.get('eventName', 'unknown')}",
        "event_time": event_time or "unknown",
        "detected_at": detected_at,
        "ttd_seconds": ttd_seconds(event_time, detected_at),
        "region": detail.get("awsRegion", "unknown"),
        "source_ip": detail.get("sourceIPAddress", "unknown"),
        "user_agent": detail.get("userAgent", "unknown"),
        "request_id": detail.get("requestID", "unknown"),
        "resource": compact_json(detail.get("requestParameters") or {}),
    }


def kubernetes_base(audit, timestamp_ms):
    event_time = audit.get("requestReceivedTimestamp") or millis_to_iso(timestamp_ms)
    detected_at = now_iso()
    obj = audit.get("objectRef") or {}
    return {
        "source": "Kubernetes Audit",
        "environment": os.environ.get("ENVIRONMENT", "production"),
        "cluster": os.environ.get("CLUSTER_NAME", ""),
        "actor": deep_get(audit, "user.username") or "unknown",
        "action": f"{audit.get('verb', 'unknown')} {obj.get('resource', 'unknown')}/{obj.get('subresource', '')}".rstrip("/"),
        "event_time": event_time,
        "detected_at": detected_at,
        "ttd_seconds": ttd_seconds(event_time, detected_at),
        "region": os.environ.get("AWS_REGION", "unknown"),
        "source_ip": ",".join(audit.get("sourceIPs") or []) or "unknown",
        "user_agent": audit.get("userAgent", "unknown"),
        "request_id": audit.get("auditID", "unknown"),
        "namespace": obj.get("namespace", ""),
        "resource": obj.get("name", "") or obj.get("resource", "unknown"),
    }


def post_discord(alert):
    body = discord_payload(alert)
    send_discord(body)
    print_delivery_evidence(
        {"rule_id": alert.get("rule", "unknown")},
        "sent",
        "success",
        0,
        0,
    )
    print(json.dumps({"posted": alert.get("rule"), "severity": alert.get("severity"), "ttd_seconds": alert.get("ttd_seconds")}))


def send_discord(body):
    request = urllib.request.Request(
        webhook_url(),
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "techx-audit-alert-router/1.0"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()


def discord_payload(alert):
    severity = alert.get("severity", "UNKNOWN")
    icon = severity_icon(severity)
    return {
        "username": "TechX Audit Alert Router",
        "content": f"{icon} **{severity} audit alert matched `{alert.get('rule', 'unknown')}`**",
        "embeds": [
            {
                "title": f"{icon} {severity} AWS Audit Detection",
                "description": alert.get("summary", ""),
                "color": severity_color(severity),
                "fields": discord_fields(alert),
                "footer": {
                    "text": "Do not paste secrets, webhook URLs, payment data, customer PII, or raw logs into Discord."
                },
                "timestamp": alert.get("detected_at", now_iso()),
            }
        ],
        "allowed_mentions": {"parse": []},
    }


def severity_icon(severity):
    if severity == "CRITICAL":
        return ":rotating_light:"
    if severity == "HIGH":
        return ":warning:"
    return ":information_source:"


def severity_color(severity):
    if severity == "CRITICAL":
        return 15158332
    if severity == "HIGH":
        return 16753920
    return 3447003


def discord_fields(alert):
    fields = [
        ("Rule", alert.get("rule", "unknown"), True),
        ("Source", alert.get("source", "unknown"), True),
        ("Environment", alert.get("environment", "production"), True),
        ("Cluster", alert.get("cluster", ""), True),
        ("Actor", alert.get("actor", "unknown"), False),
        ("Action", alert.get("action", "unknown"), False),
        ("When", alert.get("event_time", "unknown"), True),
        ("Detected at", alert.get("detected_at", "unknown"), True),
        ("TTD", f"{alert.get('ttd_seconds', 'unknown')}s", True),
        ("Region", alert.get("region", "unknown"), True),
        ("Source IP", alert.get("source_ip", "unknown"), True),
        ("Request/Audit ID", alert.get("request_id", "unknown"), False),
        ("User agent", alert.get("user_agent", "unknown"), False),
        ("Resource/Request", str(alert.get("resource", "unknown"))[:900], False),
        (
            "First action",
            "Verify the actor and approval ticket; if unapproved, revoke the change and preserve CloudTrail/Kubernetes audit evidence.",
            False,
        ),
    ]
    if alert.get("namespace"):
        fields.insert(4, ("Namespace", alert["namespace"], True))
    return [{"name": name, "value": code_block(value), "inline": inline} for name, value, inline in fields]


def code_block(value):
    value = str(value) if value is not None else "unknown"
    return f"`{value[:1000]}`"


def format_message(alert):
    icon = "!!" if alert["severity"] == "CRITICAL" else "!"
    fields = [
        f"{icon} **{alert['severity']} AWS Audit Detection**",
        f"**Rule:** `{alert.get('rule', 'unknown')}`",
        f"**Summary:** {alert.get('summary', '')}",
        f"**Source:** {alert.get('source', 'unknown')}",
        f"**Environment:** `{alert.get('environment', 'production')}`",
        f"**Cluster:** `{alert.get('cluster', '')}`",
        f"**Actor:** `{alert.get('actor', 'unknown')}`",
        f"**Action:** `{alert.get('action', 'unknown')}`",
        f"**When:** `{alert.get('event_time', 'unknown')}`",
        f"**Detected at:** `{alert.get('detected_at', 'unknown')}`",
        f"**TTD:** `{alert.get('ttd_seconds', 'unknown')}s`",
        f"**Region:** `{alert.get('region', 'unknown')}`",
        f"**Source IP:** `{alert.get('source_ip', 'unknown')}`",
        f"**User agent:** `{alert.get('user_agent', 'unknown')[:180]}`",
        f"**Request/Audit ID:** `{alert.get('request_id', 'unknown')}`",
    ]
    if alert.get("namespace"):
        fields.append(f"**Namespace:** `{alert['namespace']}`")
    fields.extend([
        f"**Resource/Request:** `{str(alert.get('resource', 'unknown'))[:500]}`",
        "**First action:** verify the actor and approval ticket; if unapproved, revoke the change and preserve CloudTrail/Kubernetes audit evidence.",
        "_Do not paste secrets, webhook URLs, payment data, customer PII, or raw logs into Discord._",
    ])
    return "\n".join(fields)


def webhook_url():
    global WEBHOOK_URL
    if WEBHOOK_URL:
        return WEBHOOK_URL
    secret = secretsmanager.get_secret_value(SecretId=os.environ["DISCORD_WEBHOOK_SECRET_NAME"])
    raw = secret.get("SecretString", "")
    key = os.environ.get("DISCORD_WEBHOOK_SECRET_JSON_KEY", "webhook-url")
    try:
        WEBHOOK_URL = json.loads(raw)[key]
    except (json.JSONDecodeError, KeyError) as exc:
        raise RuntimeError(f"Discord webhook secret must be JSON containing key {key}") from exc
    return WEBHOOK_URL


def managed_policy_is_admin(policy_arn, version_id=None):
    if not policy_arn:
        return False
    try:
        if version_id is None:
            policy = iam.get_policy(PolicyArn=policy_arn)["Policy"]
            version_id = policy["DefaultVersionId"]
        version = iam.get_policy_version(PolicyArn=policy_arn, VersionId=version_id)
        return policy_is_admin(version["PolicyVersion"]["Document"])
    except Exception as exc:
        print(json.dumps({"policy_inspection_failed": policy_arn, "error": str(exc)}))
        return False


def policy_is_admin(doc):
    if not isinstance(doc, dict):
        return False
    statements = doc.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    for stmt in statements:
        if stmt.get("Effect") != "Allow":
            continue
        if wildcard_match(stmt.get("Action")) and wildcard_match(stmt.get("Resource")):
            return True
    return False


def wildcard_match(value):
    if value == "*":
        return True
    if isinstance(value, list):
        return "*" in value
    return False


def parse_policy_doc(value):
    if not value:
        return None
    if isinstance(value, dict):
        return value
    try:
        return json.loads(urllib.parse.unquote(str(value)))
    except json.JSONDecodeError:
        return None


def disables_eks_audit_logging(request):
    for item in deep_get(request, "logging.clusterLogging") or []:
        if item.get("enabled") is False and {"api", "audit", "authenticator"}.intersection(set(item.get("types") or [])):
            return True
    return False


def request_has_privileged_workload(obj):
    if not isinstance(obj, dict):
        return False
    return any_privileged(obj)


def any_privileged(value):
    if isinstance(value, dict):
        if value.get("privileged") is True or value.get("hostPID") is True or value.get("hostNetwork") is True or value.get("hostIPC") is True:
            return True
        if "hostPath" in value:
            return True
        return any(any_privileged(v) for v in value.values())
    if isinstance(value, list):
        return any(any_privileged(v) for v in value)
    return False


def namespace_matches(namespace):
    if not namespace:
        return False
    return is_allowed(namespace, env_json("PRODUCTION_NAMESPACE_PATTERNS"))


def is_allowed(value, patterns):
    return any(re.search(pattern, value or "") for pattern in patterns)


def env_json(name):
    try:
        return json.loads(os.environ.get(name, "[]"))
    except json.JSONDecodeError:
        return []


def deep_get(data, dotted):
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def compact_json(value):
    return json.dumps(redact(value), sort_keys=True, separators=(",", ":"))[:700]


def redact(value):
    if isinstance(value, dict):
        output = {}
        for key, val in value.items():
            if re.search(r"password|secret|token|credential|authorization|webhook", key, re.I):
                output[key] = "<redacted>"
            else:
                output[key] = redact(val)
        return output
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def millis_to_iso(value):
    if value is None:
        return None
    return dt.datetime.fromtimestamp(value / 1000, tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")


def ttd_seconds(event_time, detected_at):
    try:
        start = parse_time(event_time)
        end = parse_time(detected_at)
        return round((end - start).total_seconds(), 3)
    except Exception:
        return "unknown"


def parse_time(value):
    return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))

