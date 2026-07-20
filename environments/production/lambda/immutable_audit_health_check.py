import json
import os
from datetime import datetime, timezone

import boto3


cloudtrail = boto3.client("cloudtrail")
cloudwatch = boto3.client("cloudwatch")
events = boto3.client("events")
kms = boto3.client("kms")
logs = boto3.client("logs")
s3 = boto3.client("s3")
secretsmanager = boto3.client("secretsmanager")
sns = boto3.client("sns")


def _env_json(name, default):
    value = os.environ.get(name)
    return json.loads(value) if value else default


def _age_minutes(dt):
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return (datetime.now(timezone.utc) - dt.astimezone(timezone.utc)).total_seconds() / 60


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

    selectors = cloudtrail.get_event_selectors(TrailName=trail_name).get("EventSelectors", [])
    if not selectors:
        errors.append("CloudTrail event selectors are missing")
        return

    expected_data_arns = set(_env_json("EXPECTED_S3_DATA_EVENT_ARNS", []))
    has_management = any(selector.get("IncludeManagementEvents") for selector in selectors)
    if not has_management:
        errors.append("CloudTrail management events are not included")

    actual_data_arns = {
        value
        for selector in selectors
        for resource in selector.get("DataResources", [])
        if resource.get("Type") == "AWS::S3::Object"
        for value in resource.get("Values", [])
    }
    missing_data_arns = expected_data_arns - actual_data_arns
    if missing_data_arns:
        errors.append(f"CloudTrail missing S3 data event ARNs: {sorted(missing_data_arns)}")


def _check_s3(errors):
    bucket = os.environ["AUDIT_BUCKET"]
    versioning = s3.get_bucket_versioning(Bucket=bucket)
    if versioning.get("Status") != "Enabled":
        errors.append("S3 audit bucket versioning is not Enabled")

    lock_config = s3.get_object_lock_configuration(Bucket=bucket)["ObjectLockConfiguration"]
    retention = lock_config.get("Rule", {}).get("DefaultRetention", {})
    if retention.get("Mode") != os.environ["OBJECT_LOCK_MODE"]:
        errors.append(f"S3 Object Lock mode drifted: {retention.get('Mode')}")
    if int(retention.get("Days", 0)) != int(os.environ["OBJECT_LOCK_DAYS"]):
        errors.append(f"S3 Object Lock days drifted: {retention.get('Days')}")


def _check_kms(errors):
    for key_id in _env_json("KMS_KEY_IDS", []):
        metadata = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        if metadata.get("KeyState") != "Enabled":
            errors.append(f"KMS key is not Enabled: {key_id} state={metadata.get('KeyState')}")


def _check_eventbridge(errors):
    expected_target_arns = set(_env_json("EXPECTED_TAMPER_TARGET_ARNS", []))
    for rule_name in _env_json("TAMPER_RULE_NAMES", []):
        rule = events.describe_rule(Name=rule_name)
        if rule.get("State") != "ENABLED":
            errors.append(f"EventBridge rule is not ENABLED: {rule_name}")
        targets = events.list_targets_by_rule(Rule=rule_name).get("Targets", [])
        target_arns = {target.get("Arn") for target in targets}
        missing = expected_target_arns - target_arns
        if missing:
            errors.append(f"EventBridge rule {rule_name} missing targets: {sorted(missing)}")


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
