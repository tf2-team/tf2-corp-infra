import json
import os
from datetime import datetime, timezone

import boto3
from botocore.config import Config

CONFIG = Config(
    retries={"total_max_attempts": 3, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=30,
)

cloudtrail = boto3.client("cloudtrail", config=CONFIG)
cloudwatch = boto3.client("cloudwatch", config=CONFIG)
dynamodb = boto3.client("dynamodb", config=CONFIG)
events = boto3.client("events", config=CONFIG)
kms = boto3.client("kms", config=CONFIG)
logs = boto3.client("logs", config=CONFIG)
s3 = boto3.client("s3", config=CONFIG)
secretsmanager = boto3.client("secretsmanager", config=CONFIG)
sns = boto3.client("sns", config=CONFIG)
sqs = boto3.client("sqs", config=CONFIG)


def _env_json(name, default):
    value = os.environ.get(name)
    return json.loads(value) if value else default


def _parse_time(value):
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _age_minutes(dt):
    dt = _parse_time(dt)
    return (datetime.now(timezone.utc) - dt).total_seconds() / 60


def _put_health_metric(value):
    cloudwatch.put_metric_data(
        Namespace="TechX/Audit",
        MetricData=[
            {
                "MetricName": "AuditControlHealth",
                "Dimensions": [{"Name": "TrailName", "Value": os.environ["TRAIL_NAME"]}],
                "Value": value,
                "Unit": "None",
            }
        ],
    )


def _check_cloudtrail(errors):
    trail_name = os.environ["TRAIL_NAME"]
    status = cloudtrail.get_trail_status(Name=trail_name)
    if not status.get("IsLogging"):
        errors.append("CloudTrail IsLogging is false")

    max_age = int(os.environ["MAX_DELIVERY_AGE_MINUTES"])
    for key in ["LatestDeliveryTime", "LatestCloudWatchLogsDeliveryTime", "LatestDigestDeliveryTime"]:
        if key not in status:
            errors.append(f"CloudTrail {key} is missing")
        elif _age_minutes(status[key]) > max_age:
            errors.append(f"CloudTrail {key} is stale: {status[key]}")

    trails = cloudtrail.describe_trails(trailNameList=[trail_name], includeShadowTrails=False)["trailList"]
    if not trails:
        errors.append("CloudTrail describe_trails returned no trail")
        return

    trail = trails[0]
    if not trail.get("LogFileValidationEnabled"):
        errors.append("CloudTrail log file validation is disabled")
    if trail.get("CloudWatchLogsLogGroupArn") is None:
        errors.append("CloudTrail CloudWatch Logs delivery is not configured")
    if trail.get("KmsKeyId") is None:
        errors.append("CloudTrail KMS encryption is not configured")

    selector_response = cloudtrail.get_event_selectors(TrailName=trail_name)
    selectors = selector_response.get("EventSelectors", [])
    advanced_selectors = selector_response.get("AdvancedEventSelectors", [])
    if not selectors and not advanced_selectors:
        errors.append("CloudTrail event selectors are missing")
        return

    expected_data_arns = set(_env_json("EXPECTED_S3_DATA_EVENT_ARNS", []))
    has_management = any(selector.get("IncludeManagementEvents") for selector in selectors)
    has_management = has_management or any(
        field_selector.get("Field") == "eventCategory" and "Management" in field_selector.get("Equals", [])
        for selector in advanced_selectors
        for field_selector in selector.get("FieldSelectors", [])
    )
    if not has_management:
        errors.append("CloudTrail management events are not included")

    actual_data_arns = {
        value
        for selector in selectors
        for resource in selector.get("DataResources", [])
        if resource.get("Type") == "AWS::S3::Object"
        for value in resource.get("Values", [])
    }
    for selector in advanced_selectors:
        field_selectors = selector.get("FieldSelectors", [])
        is_s3_data = any(
            item.get("Field") == "resources.type" and "AWS::S3::Object" in item.get("Equals", [])
            for item in field_selectors
        )
        if not is_s3_data:
            continue
        for item in field_selectors:
            if item.get("Field") == "resources.ARN":
                actual_data_arns.update(item.get("Equals", []))
                actual_data_arns.update(item.get("StartsWith", []))

    missing_data_arns = expected_data_arns - actual_data_arns
    if missing_data_arns:
        errors.append(f"CloudTrail missing S3 data event ARNs: {sorted(missing_data_arns)}")


def _check_object_lock_bucket(errors, bucket, mode, days, label):
    versioning = s3.get_bucket_versioning(Bucket=bucket)
    if versioning.get("Status") != "Enabled":
        errors.append(f"{label} bucket versioning is not Enabled")

    lock_config = s3.get_object_lock_configuration(Bucket=bucket)["ObjectLockConfiguration"]
    retention = lock_config.get("Rule", {}).get("DefaultRetention", {})
    if retention.get("Mode") != mode:
        errors.append(f"{label} Object Lock mode drifted: {retention.get('Mode')}")
    if int(retention.get("Days", 0)) != int(days):
        errors.append(f"{label} Object Lock days drifted: {retention.get('Days')}")


def _check_s3(errors):
    _check_object_lock_bucket(
        errors,
        os.environ["AUDIT_BUCKET"],
        os.environ["OBJECT_LOCK_MODE"],
        os.environ["OBJECT_LOCK_DAYS"],
        "CloudTrail audit",
    )
    raw_bucket = os.environ.get("RAW_ARCHIVE_BUCKET")
    if raw_bucket:
        _check_object_lock_bucket(
            errors,
            raw_bucket,
            os.environ["RAW_ARCHIVE_OBJECT_LOCK_MODE"],
            os.environ["RAW_ARCHIVE_OBJECT_LOCK_DAYS"],
            "Raw K8s archive",
        )


def _check_kms(errors):
    for key_id in _env_json("KMS_KEY_IDS", []):
        metadata = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        if metadata.get("KeyState") != "Enabled":
            errors.append(f"KMS key is not Enabled: {key_id} state={metadata.get('KeyState')}")


def _check_eventbridge(errors):
    expected_targets_by_rule = {
        **_env_json("EXPECTED_TAMPER_TARGETS_BY_RULE", {}),
        **_env_json("EXPECTED_SCHEDULED_TARGETS_BY_RULE", {}),
    }
    for rule_name in sorted(expected_targets_by_rule):
        rule = events.describe_rule(Name=rule_name)
        if rule.get("State") != "ENABLED":
            errors.append(f"EventBridge rule is not ENABLED: {rule_name}")
        targets = events.list_targets_by_rule(Rule=rule_name).get("Targets", [])
        target_arns = {target.get("Arn") for target in targets}
        expected_target_arns = set(expected_targets_by_rule.get(rule_name, []))
        missing = expected_target_arns - target_arns
        if missing:
            errors.append(f"EventBridge rule {rule_name} missing targets: {sorted(missing)}")


def _latest_validation_report(bucket, prefix):
    newest = None
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            if not item["Key"].endswith(".json"):
                continue
            if newest is None or item["LastModified"] > newest["LastModified"]:
                newest = item
    return newest


def _read_json_object(bucket, key):
    response = s3.get_object(Bucket=bucket, Key=key)
    with response["Body"] as body:
        return json.loads(body.read())


def _check_validation_reports(errors):
    bucket = os.environ.get("VALIDATION_REPORT_BUCKET")
    report_prefix = os.environ.get("VALIDATION_REPORT_PREFIX", "").strip("/")
    if not bucket or not report_prefix:
        return

    max_age = int(os.environ["MAX_VALIDATION_REPORT_AGE_MINUTES"])
    for report_type in _env_json("VALIDATION_REPORT_TYPES", []):
        prefix = f"{report_prefix}/{report_type}/"
        latest = _latest_validation_report(bucket, prefix)
        if latest is None:
            errors.append(f"Validation report missing: {report_type}")
            continue

        report = _read_json_object(bucket, latest["Key"])
        if report.get("status") != "PASS":
            errors.append(f"Latest {report_type} validation report is {report.get('status')}: {latest['Key']}")
        report_time = _parse_time(report.get("validated_at")) if report.get("validated_at") else latest["LastModified"]
        if _age_minutes(report_time) > max_age:
            errors.append(f"Latest {report_type} validation report is stale: {latest['Key']}")


def _check_k8s_sealer_checkpoint(errors):
    table_name = os.environ.get("K8S_SEALER_CHECKPOINT_TABLE")
    chain_id = os.environ.get("K8S_SEALER_CHAIN_ID")
    if not table_name or not chain_id:
        return

    response = dynamodb.get_item(
        TableName=table_name,
        Key={"chain_id": {"S": chain_id}},
        ConsistentRead=True,
    )
    item = response.get("Item")
    if not item:
        errors.append(f"K8s sealer checkpoint missing for chain_id={chain_id}")
        return
    status = item.get("status", {}).get("S")
    if status != "SEALED":
        errors.append(f"K8s sealer checkpoint status is not SEALED: {status}")
    if not item.get("last_window_end", {}).get("S"):
        errors.append("K8s sealer checkpoint last_window_end is missing")
    if not item.get("previous_manifest_hash", {}).get("S"):
        errors.append("K8s sealer checkpoint manifest hash is missing")


def _check_audit_dlqs(errors):
    max_visible = int(os.environ["MAX_DLQ_VISIBLE_MESSAGES"])
    for queue_url in _env_json("AUDIT_DLQ_URLS", []):
        response = sqs.get_queue_attributes(
            QueueUrl=queue_url,
            AttributeNames=["ApproximateNumberOfMessagesVisible"],
        )
        visible = int(response.get("Attributes", {}).get("ApproximateNumberOfMessagesVisible", "0"))
        if visible > max_visible:
            errors.append(f"Audit DLQ has {visible} visible messages: {queue_url}")


def _check_sns(errors):
    topic_arn = os.environ["TAMPER_TOPIC_ARN"]
    subs = sns.list_subscriptions_by_topic(TopicArn=topic_arn).get("Subscriptions", [])
    if not subs:
        errors.append("SNS tamper topic has no subscriptions")
        return
    pending = [sub.get("Endpoint") for sub in subs if sub.get("SubscriptionArn") == "PendingConfirmation"]
    if pending:
        errors.append(f"SNS subscriptions pending confirmation: {pending}")


def _check_logs(errors):
    group_name = os.environ["CLOUDWATCH_LOG_GROUP"]
    response = logs.describe_log_groups(logGroupNamePrefix=group_name)
    groups = [group for group in response.get("logGroups", []) if group.get("logGroupName") == group_name]
    if not groups:
        errors.append(f"CloudWatch log group missing: {group_name}")
        return
    expected_retention = int(os.environ["CLOUDWATCH_RETENTION_DAYS"])
    if groups[0].get("retentionInDays") != expected_retention:
        errors.append(f"CloudWatch retention drifted: {groups[0].get('retentionInDays')}")


def _check_discord_secret(errors):
    secret_arn = os.environ.get("DISCORD_WEBHOOK_SECRET_ARN")
    if not secret_arn:
        return
    try:
        secretsmanager.describe_secret(SecretId=secret_arn)
    except Exception as exc:
        errors.append(f"Discord webhook secret is not readable: {exc}")


def handler(_event, _context):
    errors = []
    for check in [
        _check_cloudtrail,
        _check_s3,
        _check_kms,
        _check_eventbridge,
        _check_validation_reports,
        _check_k8s_sealer_checkpoint,
        _check_audit_dlqs,
        _check_sns,
        _check_logs,
        _check_discord_secret,
    ]:
        try:
            check(errors)
        except Exception as exc:
            errors.append(f"{check.__name__} failed: {exc}")

    if errors:
        _put_health_metric(0)
        print(json.dumps({"status": "FAIL", "errors": errors}))
        raise RuntimeError("; ".join(errors))

    _put_health_metric(1)
    print(json.dumps({"status": "PASS"}))
    return {"status": "PASS"}
