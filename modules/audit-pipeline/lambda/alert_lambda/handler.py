"""
alert-lambda (techx-audit-alert-parser) — bản rỗng, chưa gửi đi đâu
---------------------------------------------------------------------
Trigger: SQS event source mapping trên queue chung (nhận cả 2 nhánh:
CloudTrail qua EventBridge Input Transformer, EKS Audit qua parse-lambda).

Việc hiện tại: chuẩn hoá severity cho nhánh CloudTrail (tra SEVERITY_MAP
theo eventName, vì EventBridge Input Transformer không làm được logic
điều kiện), nhánh EKS dùng thẳng severity đã tính sẵn từ parse-lambda —
rồi CHỈ LOG RA, chưa gửi đi bất kỳ đâu. Phần gửi (Discord/SNS/Slack/...)
để làm sau, chỉ cần thêm vào chỗ TODO trong handler().
"""

import json

# Tra severity cho nhánh CloudTrail - khớp đúng bảng MANDATE-11.1
SEVERITY_MAP = {
    "CreateAccessKey":         ("R1-create-access-key", "High"),
    "AttachUserPolicy":        ("R2-admin-policy-attach", "Critical"),
    "AttachRolePolicy":        ("R2-admin-policy-attach", "Critical"),
    "AttachGroupPolicy":       ("R2-admin-policy-attach", "Critical"),
    "PutUserPolicy":           ("R2-admin-policy-attach", "Critical"),
    "PutRolePolicy":           ("R2-admin-policy-attach", "Critical"),
    "PutGroupPolicy":          ("R2-admin-policy-attach", "Critical"),
    "CreatePolicyVersion":     ("R2-admin-policy-attach", "Critical"),
    "SetDefaultPolicyVersion": ("R2-admin-policy-attach", "Critical"),
    "CreateAccessEntry":       ("R3-eks-access-entry", "Critical"),
    "AssociateAccessPolicy":   ("R4-eks-cluster-admin-policy", "Critical"),
    "UpdateClusterConfig":     ("R5-eks-audit-logging-change", "Critical"),
    "StopLogging":             ("R6-cloudtrail-tamper", "Critical"),
    "DeleteTrail":             ("R6-cloudtrail-tamper", "Critical"),
    "UpdateTrail":             ("R6-cloudtrail-tamper", "Critical"),
    "PutEventSelectors":       ("R6-cloudtrail-tamper", "Critical"),
    "DeleteEventDataStore":    ("R6-cloudtrail-tamper", "Critical"),
    "UpdateEventDataStore":    ("R6-cloudtrail-tamper", "Critical"),
    "CreateLoginProfile":      ("R12-console-login-created", "Medium"),
    "UpdateLoginProfile":      ("R12-console-login-created", "Medium"),
}


def _normalize(body: dict) -> dict:
    """Chuẩn hoá message về cùng 1 shape, bất kể tới từ nhánh nào."""
    if body.get("source") == "cloudtrail":
        event_name = body.get("eventName", "Unknown")
        rule_id, severity = SEVERITY_MAP.get(event_name, ("R0-unmapped", "Medium"))
        return {
            "source": "cloudtrail",
            "rule_id": rule_id,
            "severity": severity,
            "actor": body.get("actor", "unknown"),
            "action": event_name,
            "resource": body.get("eventSource", ""),
            "namespace": None,
            "source_ip": body.get("sourceIp", ""),
            "event_time": body.get("eventTime", ""),
        }
    # Nhánh eks-audit: đã đúng shape từ parse-lambda
    return body


def handler(event, context):
    received = 0
    for record in event.get("Records", []):
        body = json.loads(record["body"])
        item = _normalize(body)

        print(json.dumps(item))  # tạm thời chỉ log ra CloudWatch Logs của chính Lambda này
        # TODO: gửi item đi đâu đó (Discord/SNS/Slack/...) khi cần, chưa làm ở bước này

        received += 1

    return {"received": received}
