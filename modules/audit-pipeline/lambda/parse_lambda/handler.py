"""
parse-lambda (nhánh EKS Audit)
------------------------------
Destination của CloudWatch Logs Subscription Filter trên log group
/aws/eks/techx-tf2-prod/cluster.

Việc: decode payload awslogs.data (base64+gzip), áp đúng logic phân loại
theo bảng MANDATE-11.1 (roleRef, privileged container[], allowlist actor,
namespace prefix), rồi gửi 1 "envelope chuẩn" vào SQS - CÙNG SCHEMA với
những gì EventBridge Input Transformer tạo ra cho nhánh CloudTrail, để
Alert Lambda phía sau không cần phân biệt nguồn.

Env vars cần cấu hình:
  SQS_QUEUE_URL              = URL của SQS queue chung (KHÔNG phải ARN)
  ALLOWED_ACTORS              = CSV allowlist (Tuning Notes MANDATE-11.1), để trống nếu chưa có
  PRODUCTION_NAMESPACE_PREFIX = "techx-"
"""

import base64
import gzip
import json
import os
import boto3

sqs = boto3.client("sqs")
SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
ALLOWED_ACTORS = set(
    a.strip() for a in os.environ.get("ALLOWED_ACTORS", "").split(",") if a.strip()
)
PROD_NS_PREFIX = os.environ.get("PRODUCTION_NAMESPACE_PREFIX", "techx-")


def _is_allowlisted(actor: str) -> bool:
    return actor in ALLOWED_ACTORS


def _has_privileged_container(request_object: dict) -> bool:
    if not request_object:
        return False
    spec = request_object.get("spec", {})
    if "template" in spec:
        spec = spec.get("template", {}).get("spec", {})
    if spec.get("hostPID") or spec.get("hostNetwork") or spec.get("hostIPC"):
        return True
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        if (c.get("securityContext", {}) or {}).get("privileged") is True:
            return True
    for v in spec.get("volumes", []) or []:
        if "hostPath" in v:
            return True
    return False


def _is_cluster_admin_binding(request_object: dict) -> bool:
    if not request_object:
        return False
    return (request_object.get("roleRef", {}) or {}).get("name") == "cluster-admin"


def classify(event: dict):
    """Trả (rule_id, severity, reason) nếu khớp rule MANDATE-11.1, None nếu loại bỏ."""
    verb = event.get("verb", "")
    obj = event.get("objectRef", {}) or {}
    resource = obj.get("resource", "")
    subresource = obj.get("subresource", "")
    namespace = obj.get("namespace", "") or ""
    actor = (event.get("user", {}) or {}).get("username", "")
    req_obj = event.get("requestObject")

    if _is_allowlisted(actor):
        return None

    if resource == "pods" and subresource == "exec" and verb == "create":
        return ("R9-pod-exec", "High", "Exec vào pod")

    if resource in ("clusterrolebindings", "rolebindings") and verb in ("create", "update", "patch"):
        if _is_cluster_admin_binding(req_obj):
            return ("R7-cluster-admin-binding", "Critical", f"{resource} trỏ tới cluster-admin")
        return ("R7b-rbac-binding-change", "Medium", f"{resource} bị thay đổi (chưa xác nhận cluster-admin)")

    if resource == "secrets" and verb in ("get", "list", "watch"):
        return ("R8-secrets-read", "High", f"Đọc secrets bởi {actor}")

    if resource in ("pods", "deployments", "statefulsets", "daemonsets", "jobs", "cronjobs") and verb in (
        "create", "update", "patch",
    ):
        if _has_privileged_container(req_obj):
            return ("R10-privileged-workload", "Critical", f"{resource} có privileged/hostPath/hostNetwork")

    if verb in ("delete", "deletecollection") and resource in (
        "deployments", "statefulsets", "daemonsets", "services", "ingresses", "configmaps", "secrets",
    ):
        if namespace.startswith(PROD_NS_PREFIX):
            return ("R11-prod-delete", "High", f"Xóa {resource} trong namespace production {namespace}")

    return None


def _to_envelope(event: dict, rule_id: str, severity: str, reason: str) -> dict:
    """Schema chuẩn dùng chung với nhánh CloudTrail (EventBridge Input Transformer)."""
    return {
        "source": "eks-audit",
        "rule_id": rule_id,
        "severity": severity,
        "reason": reason,
        "actor": (event.get("user", {}) or {}).get("username"),
        "action": event.get("verb"),
        "resource": (event.get("objectRef", {}) or {}).get("resource"),
        "namespace": (event.get("objectRef", {}) or {}).get("namespace"),
        "source_ip": ",".join(event.get("sourceIPs", []) or []),
        "event_time": event.get("requestReceivedTimestamp") or event.get("stageTimestamp"),
        "audit_id": event.get("auditID"),
    }


def handler(event, context):
    payload = base64.b64decode(event["awslogs"]["data"])
    log_data = json.loads(gzip.decompress(payload))

    sent = 0
    for log_event in log_data.get("logEvents", []):
        try:
            k8s_event = json.loads(log_event["message"])
        except (KeyError, json.JSONDecodeError):
            continue

        result = classify(k8s_event)
        if result is None:
            continue

        rule_id, severity, reason = result
        envelope = _to_envelope(k8s_event, rule_id, severity, reason)

        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(envelope),
        )
        sent += 1

    return {"sent_to_sqs": sent}
