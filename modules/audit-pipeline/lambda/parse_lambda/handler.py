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

def lambda_handler(event, context):
    # In toàn bộ log mà 11.2 ném sang ra CloudWatch để làm bằng chứng
    print("=== DỮ LIỆU LOG NHẬN ĐƯỢC TỪ TASK 11.2 ===")
    print(json.dumps(event))

    return {
        'statusCode': 200,
        'body': 'Đã nhận log thành công!'
    }