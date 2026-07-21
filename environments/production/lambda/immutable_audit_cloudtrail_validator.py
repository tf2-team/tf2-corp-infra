import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config


CONFIG = Config(
    retries={"total_max_attempts": 3, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=30,
)

cloudtrail = boto3.client("cloudtrail", config=CONFIG)
cloudwatch = boto3.client("cloudwatch", config=CONFIG)
s3 = boto3.client("s3", config=CONFIG)


def _iso(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _age_minutes(value, now):
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return (now - value.astimezone(timezone.utc)).total_seconds() / 60


def _list_count(bucket, prefix, limit=25):
    count = 0
    samples = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            count += 1
            if len(samples) < limit:
                samples.append(
                    {
                        "key": item["Key"],
                        "last_modified": _iso(item["LastModified"]),
                        "size": item["Size"],
                    }
                )
    return count, samples


def _put_metric(value):
    cloudwatch.put_metric_data(
        Namespace="TechX/Audit",
        MetricData=[
            {
                "MetricName": "ImmutableAuditCloudTrailValidationPass",
                "Dimensions": [{"Name": "TrailName", "Value": os.environ["TRAIL_NAME"]}],
                "Value": value,
                "Unit": "None",
            }
        ],
    )


def _put_report(report):
    timestamp = _parse_time(report["validated_at"])
    key = (
        f"{os.environ['REPORT_PREFIX'].strip('/')}/cloudtrail/"
        f"year={timestamp:%Y}/month={timestamp:%m}/day={timestamp:%d}/"
        f"{timestamp:%H%M%S}-{report['status'].lower()}.json"
    )
    s3.put_object(
        Bucket=os.environ["REPORT_BUCKET"],
        Key=key,
        Body=json.dumps(report, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        ContentType="application/json",
    )
    return key


def _validate(event):
    now = datetime.now(timezone.utc)
    account_id = os.environ["ACCOUNT_ID"]
    bucket = os.environ["TRAIL_BUCKET"]
    max_age = int(os.environ["MAX_DELIVERY_AGE_MINUTES"])
    region = os.environ["AWS_REGION_NAME"]
    trail_name = os.environ["TRAIL_NAME"]
    window_end = now - timedelta(minutes=int(os.environ["VALIDATION_DELAY_MINUTES"]))
    window_start = window_end - timedelta(hours=int(os.environ["VALIDATION_LOOKBACK_HOURS"]))
    if event.get("window_start") and event.get("window_end"):
        window_start = _parse_time(event["window_start"])
        window_end = _parse_time(event["window_end"])

    errors = []
    status = cloudtrail.get_trail_status(Name=trail_name)
    trails = cloudtrail.describe_trails(trailNameList=[trail_name], includeShadowTrails=False)["trailList"]
    if not status.get("IsLogging"):
        errors.append("CloudTrail IsLogging is false")
    if not trails:
        errors.append("CloudTrail describe_trails returned no trail")
        trail = {}
    else:
        trail = trails[0]
        if not trail.get("LogFileValidationEnabled"):
            errors.append("CloudTrail log file validation is disabled")
        if trail.get("S3BucketName") != bucket:
            errors.append(f"CloudTrail bucket drifted: {trail.get('S3BucketName')}")

    for key in ["LatestDeliveryTime", "LatestDigestDeliveryTime"]:
        if key not in status:
            errors.append(f"CloudTrail {key} missing")
        elif _age_minutes(status[key], now) > max_age:
            errors.append(f"CloudTrail {key} stale: {_iso(status[key])}")

    day = window_start
    digest_count = 0
    log_count = 0
    digest_samples = []
    log_samples = []
    while day.date() <= window_end.date():
        digest_prefix = f"AWSLogs/{account_id}/CloudTrail-Digest/{region}/{day:%Y/%m/%d}/"
        log_prefix = f"AWSLogs/{account_id}/CloudTrail/{region}/{day:%Y/%m/%d}/"
        day_digest_count, day_digest_samples = _list_count(bucket, digest_prefix)
        day_log_count, day_log_samples = _list_count(bucket, log_prefix)
        digest_count += day_digest_count
        log_count += day_log_count
        digest_samples.extend(day_digest_samples)
        log_samples.extend(day_log_samples)
        day += timedelta(days=1)

    if digest_count == 0:
        errors.append("No CloudTrail digest objects found in validation lookback")
    if log_count == 0:
        errors.append("No CloudTrail log objects found in validation lookback")

    report = {
        "schema_version": "2026-07-21",
        "validator": "cloudtrail-digest-presence",
        "trail_name": trail_name,
        "trail_arn": trail.get("TrailARN"),
        "validated_at": _iso(now),
        "window_start": _iso(window_start),
        "window_end": _iso(window_end),
        "status": "PASS" if not errors else "FAIL",
        "errors": errors,
        "log_file_validation_enabled": bool(trail.get("LogFileValidationEnabled")),
        "latest_delivery_time": _iso(status["LatestDeliveryTime"]) if "LatestDeliveryTime" in status else None,
        "latest_digest_delivery_time": _iso(status["LatestDigestDeliveryTime"]) if "LatestDigestDeliveryTime" in status else None,
        "digest_object_count": digest_count,
        "log_object_count": log_count,
        "digest_samples": digest_samples[:25],
        "log_samples": log_samples[:25],
        "operator_note": "Run aws cloudtrail validate-logs for cryptographic digest/signature validation; this Lambda validates scheduled control health and report freshness.",
    }
    return report


def handler(event, _context):
    report = _validate(event or {})
    report_key = _put_report(report)
    _put_metric(1 if report["status"] == "PASS" else 0)
    print(json.dumps({"status": report["status"], "report_key": report_key}, sort_keys=True))
    if report["status"] != "PASS":
        raise RuntimeError("; ".join(report["errors"]))
    return {"status": report["status"], "report_key": report_key}
