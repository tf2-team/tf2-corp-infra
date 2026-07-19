"""
k8s-audit-fine-filter
----------------------
Lambda đích của CloudWatch Logs Subscription Filter trên log group
/aws/eks/techx-tf2-prod/cluster.

Subscription filter (lớp thô) đã giảm traffic xuống chỉ còn các
resource/verb khả nghi. Lambda này áp đúng logic chi tiết theo bảng
MANDATE-11.1 (mục #7-#11), gắn rule_id/severity, rồi đẩy record đã
khớp sang Kinesis Firehose -> S3.

Env vars cần cấu hình khi tạo Lambda:
  FIREHOSE_STREAM_NAME   = techx-prod-tf2-audit-events-stream
  ALLOWED_ACTORS         = "system:serviceaccount:argocd:argocd-application-controller,system:serviceaccount:kube-system:cluster-autoscaler"
                            (CSV allowlist theo Tuning Notes 11.1 - CI/CD roles, controllers)
  PRODUCTION_NAMESPACE_PREFIX = "techx-"
"""

import base64
import gzip
import json
import os
import boto3

firehose = boto3.client("firehose")
FIREHOSE_STREAM_NAME = os.environ["FIREHOSE_STREAM_NAME"]
ALLOWED_ACTORS = set(
    a.strip() for a in os.environ.get("ALLOWED_ACTORS", "").split(",") if a.strip()
)
PROD_NS_PREFIX = os.environ.get("PRODUCTION_NAMESPACE_PREFIX", "techx-")


def _is_allowlisted(actor: str) -> bool:
    """Tuning Notes 11.1: giữ allowlist cho CI/CD role, controller, break-glass identity."""
    return actor in ALLOWED_ACTORS


def _has_privileged_container(request_object: dict) -> bool:
    """
    Duyệt TOÀN BỘ mảng containers + initContainers (CloudWatch filter pattern
    không làm được việc này vì không duyệt mảng đáng tin cậy - đây là lý do
    chính phải dùng Lambda thay vì chỉ dùng subscription filter pattern).
    """
    if not request_object:
        return False
    spec = request_object.get("spec", {})
    # Deployment/StatefulSet/DaemonSet/Job/CronJob bọc spec trong template
    if "template" in spec:
        spec = spec.get("template", {}).get("spec", {})
    if spec.get("hostPID") or spec.get("hostNetwork") or spec.get("hostIPC"):
        return True
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        sc = c.get("securityContext", {}) or {}
        if sc.get("privileged") is True:
            return True
    for v in spec.get("volumes", []) or []:
        if "hostPath" in v:
            return True
    return False


def _is_cluster_admin_binding(request_object: dict) -> bool:
    """#7: create/update/patch clusterrolebindings|rolebindings -> roleRef.name=cluster-admin."""
    if not request_object:
        return False
    role_ref = request_object.get("roleRef", {}) or {}
    return role_ref.get("name") == "cluster-admin"


def classify(event: dict):
    """
    Trả về (rule_id, severity, reason) nếu event khớp một trong các rule
    của MANDATE-11.1, hoặc None nếu không khớp (loại bỏ).
    """
    verb = event.get("verb", "")
    obj = event.get("objectRef", {}) or {}
    resource = obj.get("resource", "")
    subresource = obj.get("subresource", "")
    namespace = obj.get("namespace", "") or ""
    actor = (event.get("user", {}) or {}).get("username", "")
    req_obj = event.get("requestObject")

    if _is_allowlisted(actor):
        return None

    # #9 - exec vào pod (High) - ưu tiên vì subresource rất đặc thù
    if resource == "pods" and subresource == "exec" and verb == "create":
        return ("R9-pod-exec", "High", "Exec vào pod")

    # #7 - binding tới cluster-admin (Critical)
    if resource in ("clusterrolebindings", "rolebindings") and verb in (
        "create", "update", "patch",
    ):
        if _is_cluster_admin_binding(req_obj):
            return ("R7-cluster-admin-binding", "Critical",
                     f"{resource} trỏ tới cluster-admin")
        # Không trỏ cluster-admin -> vẫn là thay đổi RBAC, hạ severity, vẫn giữ
        # lại vì đây là loại thay đổi nhạy cảm dù chưa xác nhận là cluster-admin.
        return ("R7b-rbac-binding-change", "Medium",
                 f"{resource} bị thay đổi (chưa xác nhận cluster-admin)")

    # #8 - đọc/list secrets bởi identity không nằm trong allowlist (High)
    if resource == "secrets" and verb in ("get", "list", "watch"):
        return ("R8-secrets-read", "High", f"Đọc secrets bởi {actor}")

    # #10 - privileged workload (Critical)
    if resource in (
        "pods", "deployments", "statefulsets", "daemonsets", "jobs", "cronjobs",
    ) and verb in ("create", "update", "patch"):
        if _has_privileged_container(req_obj):
            return ("R10-privileged-workload", "Critical",
                     f"{resource} có privileged/hostPath/hostNetwork")

    # #11 - xóa workload/core service trong namespace production (High)
    if verb in ("delete", "deletecollection") and resource in (
        "deployments", "statefulsets", "daemonsets", "services", "ingresses",
        "configmaps", "secrets",
    ):
        if namespace.startswith(PROD_NS_PREFIX):
            return ("R11-prod-delete", "High",
                     f"Xóa {resource} trong namespace production {namespace}")

    return None


def _to_firehose_record(event: dict, rule_id: str, severity: str, reason: str) -> dict:
    enriched = {
        "rule_id": rule_id,
        "severity": severity,
        "reason": reason,
        "actor": (event.get("user", {}) or {}).get("username"),
        "groups": (event.get("user", {}) or {}).get("groups", []),
        "verb": event.get("verb"),
        "resource": (event.get("objectRef", {}) or {}).get("resource"),
        "subresource": (event.get("objectRef", {}) or {}).get("subresource"),
        "namespace": (event.get("objectRef", {}) or {}).get("namespace"),
        "object_name": (event.get("objectRef", {}) or {}).get("name"),
        "source_ip": event.get("sourceIPs", []),
        "user_agent": event.get("userAgent"),
        "audit_id": event.get("auditID"),
        "event_time": event.get("requestReceivedTimestamp") or event.get("stageTimestamp"),
        "raw": event,
    }
    return {"Data": (json.dumps(enriched) + "\n").encode("utf-8")}


def handler(event, context):
    payload = base64.b64decode(event["awslogs"]["data"])
    log_data = json.loads(gzip.decompress(payload))

    records = []
    for log_event in log_data.get("logEvents", []):
        try:
            k8s_event = json.loads(log_event["message"])
        except (KeyError, json.JSONDecodeError):
            continue

        result = classify(k8s_event)
        if result is None:
            continue  # loại bỏ - đúng yêu cầu 11.2: log thường không đi tiếp

        rule_id, severity, reason = result
        records.append(_to_firehose_record(k8s_event, rule_id, severity, reason))

    if not records:
        return {"forwarded": 0}

    # Firehose put_record_batch giới hạn 500 record/lần
    forwarded = 0
    for i in range(0, len(records), 500):
        batch = records[i : i + 500]
        resp = firehose.put_record_batch(
            DeliveryStreamName=FIREHOSE_STREAM_NAME, Records=batch
        )
        forwarded += len(batch) - resp.get("FailedPutCount", 0)

    return {"forwarded": forwarded, "total_matched": len(records)}
