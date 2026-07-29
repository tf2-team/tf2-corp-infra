#!/usr/bin/env python3
"""Inspect or immutably archive the three production immutable-audit DLQs."""

import argparse
import base64
import hashlib
import ipaddress
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse

import boto3


ARCHIVE_PREFIX = "immutable-audit/dlq-archive"
DEFAULT_TERRAFORM_OUTPUT = Path("environments/production/terraform-output.json")
MAX_OUTPUT_BYTES = 2 * 1024 * 1024
PRODUCTION_ACCOUNT_ID = "493499579600"
PRODUCTION_REGION = "us-east-1"
EMPTY_RECEIVE_CONFIRMATIONS = 2
MAX_RECEIVE_BATCHES = 1000
QUEUE_OUTPUT_KEYS = (
    "immutable_audit_discord_dlq_url",
    "immutable_audit_k8s_sealer_dlq_url",
    "immutable_audit_validation_dlq_url",
)
QUEUE_ATTRIBUTE_NAMES = (
    "ApproximateNumberOfMessages",
    "ApproximateNumberOfMessagesNotVisible",
    "ApproximateNumberOfMessagesDelayed",
)
BUCKET_PATTERN = re.compile(
    r"^(?!xn--)(?!.*\.\.)(?!.*-s3alias$)(?!.*--ol-s3$)"
    r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$"
)
QUEUE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,80}$")
LAMBDA_NAME_PATTERN = re.compile(r"^[A-Za-z0-9-_]{1,64}$")


class ArchiveError(RuntimeError):
    """A fail-closed operational error safe to print."""


@dataclass(frozen=True)
class QueueTarget:
    label: str
    output_key: str
    url: str
    producers: tuple[str, ...]
    alarms: tuple[str, ...]


@dataclass(frozen=True)
class ArchiveConfig:
    bucket: str
    region: str
    account_id: str
    queues: tuple[QueueTarget, ...]


def _require_success(response, operation):
    if not isinstance(response, dict):
        raise ArchiveError(f"{operation} returned an invalid response")
    metadata = response.get("ResponseMetadata")
    if not isinstance(metadata, dict) or metadata.get("HTTPStatusCode") != 200:
        raise ArchiveError(f"{operation} did not return a complete successful response")
    return response


def _read_terraform_outputs(path):
    try:
        resolved = path.resolve(strict=True)
        if not resolved.is_file() or resolved.stat().st_size > MAX_OUTPUT_BYTES:
            raise ArchiveError("Terraform output JSON must be a bounded regular file")
        payload = json.loads(resolved.read_text(encoding="utf-8"))
    except ArchiveError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ArchiveError("Terraform output JSON could not be read safely") from error
    if not isinstance(payload, dict):
        raise ArchiveError("Terraform output JSON must contain an object")
    return payload


def _output_value(outputs, key):
    entry = outputs.get(key)
    if not isinstance(entry, dict) or "value" not in entry:
        raise ArchiveError(f"required Terraform output is missing: {key}")
    value = entry["value"]
    if not isinstance(value, str) or not value:
        raise ArchiveError(f"required Terraform output is not enabled: {key}")
    return value


def _validate_bucket(bucket):
    if not isinstance(bucket, str) or not BUCKET_PATTERN.fullmatch(bucket):
        raise ArchiveError("archive bucket name is invalid")
    try:
        ipaddress.ip_address(bucket)
    except ValueError:
        return bucket
    raise ArchiveError("archive bucket name must not be an IP address")


def _parse_queue_url(url):
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.port
        or parsed.params
        or parsed.query
        or parsed.fragment
        or not parsed.hostname
    ):
        raise ArchiveError("Terraform output contains an invalid SQS queue URL")
    hostname_parts = parsed.hostname.split(".")
    if (
        len(hostname_parts) not in (4, 5)
        or hostname_parts[0] != "sqs"
        or hostname_parts[2:4] != ["amazonaws", "com"]
        or (len(hostname_parts) == 5 and hostname_parts[4] != "cn")
    ):
        raise ArchiveError("Terraform output contains a non-SQS queue URL")
    region = hostname_parts[1]
    path_parts = parsed.path.strip("/").split("/")
    if (
        len(path_parts) != 2
        or not re.fullmatch(r"\d{12}", path_parts[0])
        or not QUEUE_NAME_PATTERN.fullmatch(path_parts[1])
    ):
        raise ArchiveError("Terraform output contains an invalid SQS queue path")
    return region, path_parts[1]


def _validate_lambda_name(name, output_key):
    if not isinstance(name, str) or not LAMBDA_NAME_PATTERN.fullmatch(name):
        raise ArchiveError(f"required Terraform output is invalid: {output_key}")
    return name


def _output_mapping(outputs, key):
    entry = outputs.get(key)
    value = entry.get("value") if isinstance(entry, dict) else None
    if not isinstance(value, dict) or not value:
        raise ArchiveError(f"required Terraform output is missing: {key}")
    if any(not isinstance(name, str) or not name for name in value.values()):
        raise ArchiveError(f"required Terraform output is invalid: {key}")
    return value


def load_config(terraform_output_path, explicit_bucket=None):
    outputs = _read_terraform_outputs(terraform_output_path)
    output_bucket = _validate_bucket(
        _output_value(outputs, "immutable_audit_k8s_raw_archive_bucket_name")
    )
    if explicit_bucket is not None and _validate_bucket(explicit_bucket) != output_bucket:
        raise ArchiveError("archive bucket override must match the Terraform output")
    bucket = output_bucket
    urls = {key: _output_value(outputs, key) for key in QUEUE_OUTPUT_KEYS}
    parsed = {key: _parse_queue_url(url) for key, url in urls.items()}
    regions = {region for region, _queue_name in parsed.values()}
    accounts = {
        urlparse(url).path.strip("/").split("/")[0] for url in urls.values()
    }
    if (
        len(regions) != 1
        or len(accounts) != 1
        or len(set(urls.values())) != len(QUEUE_OUTPUT_KEYS)
    ):
        raise ArchiveError("immutable-audit DLQ outputs are ambiguous")
    region = regions.pop()
    account_id = accounts.pop()
    if account_id != PRODUCTION_ACCOUNT_ID or region != PRODUCTION_REGION:
        raise ArchiveError("Terraform outputs are not the pinned production account and region")

    discord_name = parsed["immutable_audit_discord_dlq_url"][1]
    if not discord_name.endswith("-discord-dlq"):
        raise ArchiveError("Discord DLQ does not match the production naming contract")
    discord_producer = discord_name[: -len("-discord-dlq")] + "-discord-forwarder"
    _validate_lambda_name(discord_producer, "derived Discord producer")

    sealer_producer = _validate_lambda_name(
        _output_value(outputs, "immutable_audit_k8s_sealer_lambda_name"),
        "immutable_audit_k8s_sealer_lambda_name",
    )
    if parsed["immutable_audit_k8s_sealer_dlq_url"][1] != f"{sealer_producer}-dlq":
        raise ArchiveError("K8s sealer DLQ does not match its production producer")

    cloudtrail_validator = _validate_lambda_name(
        _output_value(outputs, "immutable_audit_cloudtrail_validator_lambda_name"),
        "immutable_audit_cloudtrail_validator_lambda_name",
    )
    k8s_validator = _validate_lambda_name(
        _output_value(outputs, "immutable_audit_k8s_manifest_validator_lambda_name"),
        "immutable_audit_k8s_manifest_validator_lambda_name",
    )
    cloudtrail_prefix = cloudtrail_validator.removesuffix("-cloudtrail-validator")
    k8s_prefix = k8s_validator.removesuffix("-k8s-manifest-validator")
    validation_name = parsed["immutable_audit_validation_dlq_url"][1]
    if (
        cloudtrail_prefix == cloudtrail_validator
        or k8s_prefix == k8s_validator
        or cloudtrail_prefix != k8s_prefix
        or validation_name != f"{cloudtrail_prefix}-audit-validation-dlq"
    ):
        raise ArchiveError("validation DLQ does not match its production producers")
    producer_alarms = _output_mapping(
        outputs, "immutable_audit_dlq_producer_alarm_names"
    )
    expected_alarm_keys = {
        "discord_errors",
        "discord_throttles",
        "k8s_sealer_errors",
        "cloudtrail_validation",
        "k8s_manifest_validation",
    }
    if set(producer_alarms) != expected_alarm_keys:
        raise ArchiveError("producer alarm output does not match the production contract")

    return ArchiveConfig(
        bucket=bucket,
        region=region,
        account_id=account_id,
        queues=(
            QueueTarget(
                "discord",
                "immutable_audit_discord_dlq_url",
                urls["immutable_audit_discord_dlq_url"],
                (discord_producer,),
                (
                    producer_alarms["discord_errors"],
                    producer_alarms["discord_throttles"],
                ),
            ),
            QueueTarget(
                "k8s-sealer",
                "immutable_audit_k8s_sealer_dlq_url",
                urls["immutable_audit_k8s_sealer_dlq_url"],
                (sealer_producer,),
                (producer_alarms["k8s_sealer_errors"],),
            ),
            QueueTarget(
                "validation",
                "immutable_audit_validation_dlq_url",
                urls["immutable_audit_validation_dlq_url"],
                (cloudtrail_validator, k8s_validator),
                (
                    producer_alarms["cloudtrail_validation"],
                    producer_alarms["k8s_manifest_validation"],
                ),
            ),
        ),
    )
def _check_live_identity(sts_client, config):
    response = _require_success(sts_client.get_caller_identity(), "STS identity check")
    if response.get("Account") != config.account_id:
        raise ArchiveError("AWS caller account does not match the production queue account")


def _check_object_lock(s3_client, config):
    response = _require_success(
        s3_client.get_object_lock_configuration(
            Bucket=config.bucket, ExpectedBucketOwner=config.account_id
        ),
        "S3 Object Lock check",
    )
    configuration = response.get("ObjectLockConfiguration")
    rule = configuration.get("Rule") if isinstance(configuration, dict) else None
    retention = rule.get("DefaultRetention") if isinstance(rule, dict) else None
    duration = (
        retention.get("Days", 0) or retention.get("Years", 0)
        if isinstance(retention, dict)
        else 0
    )
    if (
        not isinstance(configuration, dict)
        or not isinstance(retention, dict)
        or configuration.get("ObjectLockEnabled") != "Enabled"
        or retention.get("Mode") not in ("GOVERNANCE", "COMPLIANCE")
        or not isinstance(duration, int)
        or duration <= 0
    ):
        raise ArchiveError("archive bucket Object Lock is not safely configured")


def _check_producers(lambda_client, cloudwatch_client, queue):
    for producer in queue.producers:
        response = _require_success(
            lambda_client.get_function_configuration(FunctionName=producer),
            f"{queue.label} producer health check",
        )
        if (
            response.get("FunctionName") != producer
            or response.get("State") != "Active"
            or response.get("LastUpdateStatus") != "Successful"
        ):
            raise ArchiveError(f"{queue.label} producer is not healthy")
    response = _require_success(
        cloudwatch_client.describe_alarms(AlarmNames=list(queue.alarms)),
        f"{queue.label} producer alarm check",
    )
    alarms = response.get("MetricAlarms")
    if not isinstance(alarms, list) or len(alarms) != len(queue.alarms):
        raise ArchiveError(f"{queue.label} producer alarm evidence is incomplete")
    states = {alarm.get("AlarmName"): alarm.get("StateValue") for alarm in alarms}
    if set(states) != set(queue.alarms) or any(state != "OK" for state in states.values()):
        raise ArchiveError(f"{queue.label} producer alarms are not healthy")


def _queue_counts(sqs_client, config, queue):
    response = _require_success(
        sqs_client.get_queue_attributes(
            QueueUrl=queue.url,
            AttributeNames=[*QUEUE_ATTRIBUTE_NAMES, "QueueArn"],
        ),
        f"{queue.label} queue inspection",
    )
    attributes = response.get("Attributes")
    if not isinstance(attributes, dict):
        raise ArchiveError(f"{queue.label} queue inspection is incomplete")
    queue_name = urlparse(queue.url).path.strip("/").split("/")[1]
    expected_arn = f"arn:aws:sqs:{config.region}:{config.account_id}:{queue_name}"
    if attributes.get("QueueArn") != expected_arn:
        raise ArchiveError(f"{queue.label} queue ARN does not match production")
    counts = {}
    for name in QUEUE_ATTRIBUTE_NAMES:
        value = attributes.get(name)
        if not isinstance(value, str) or not value.isdigit():
            raise ArchiveError(f"{queue.label} queue inspection is incomplete")
        counts[name] = int(value)
    return counts


def inspect(config, sqs_client, s3_client, lambda_client, cloudwatch_client, sts_client):
    _check_live_identity(sts_client, config)
    _check_object_lock(s3_client, config)
    queues = []
    for queue in config.queues:
        _check_producers(lambda_client, cloudwatch_client, queue)
        queues.append(
            {"queue": queue.label, "counts": _queue_counts(sqs_client, config, queue)}
        )
    return {"mode": "inspect", "status": "PASS", "queues": queues}
def _archive_document(queue, message):
    required = ("MessageId", "ReceiptHandle", "Body")
    if any(not isinstance(message.get(name), str) or not message[name] for name in required):
        raise ArchiveError(f"{queue.label} receive response contains an invalid message")
    if "Attributes" not in message or "MessageAttributes" not in message:
        raise ArchiveError(f"{queue.label} receive response is incomplete")
    attributes = message["Attributes"]
    message_attributes = message["MessageAttributes"]
    if not isinstance(attributes, dict) or not isinstance(message_attributes, dict):
        raise ArchiveError(f"{queue.label} receive response contains invalid attributes")
    document = {
        "schema_version": 1,
        "source_queue": queue.label,
        "message_id": message["MessageId"],
        "body": message["Body"],
        "system_attributes": attributes,
        "message_attributes": message_attributes,
        "md5_of_body": message.get("MD5OfBody"),
        "md5_of_message_attributes": message.get("MD5OfMessageAttributes"),
    }
    body = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        default=lambda value: {
            "base64": base64.b64encode(value).decode("ascii")
        } if isinstance(value, bytes) else (_ for _ in ()).throw(TypeError()),
    ).encode("utf-8")
    digest = hashlib.sha256(body).hexdigest()
    message_id_digest = hashlib.sha256(message["MessageId"].encode("utf-8")).hexdigest()
    key = f"{ARCHIVE_PREFIX}/{queue.label}/{message_id_digest}/{digest}.json"
    return body, digest, key


def _future_retention(value):
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError as error:
            raise ArchiveError("archive retention timestamp is invalid") from error
    if not isinstance(value, datetime) or value.tzinfo is None:
        raise ArchiveError("archive retention timestamp is invalid")
    return value.astimezone(timezone.utc) > datetime.now(timezone.utc)


def _archive_and_delete(config, queue, message, sqs_client, s3_client):
    body, digest, key = _archive_document(queue, message)
    checksum = base64.b64encode(hashlib.sha256(body).digest()).decode("ascii")
    put_response = _require_success(
        s3_client.put_object(
            Bucket=config.bucket,
            Key=key,
            Body=body,
            ContentType="application/json",
            ChecksumSHA256=checksum,
            Metadata={"archive-sha256": digest, "source-queue": queue.label},
            ExpectedBucketOwner=config.account_id,
        ),
        f"{queue.label} archive write",
    )
    version_id = put_response.get("VersionId")
    if not isinstance(version_id, str) or not version_id:
        raise ArchiveError(f"{queue.label} archive write did not return a version")
    head_response = _require_success(
        s3_client.head_object(
            Bucket=config.bucket,
            Key=key,
            VersionId=version_id,
            ChecksumMode="ENABLED",
            ExpectedBucketOwner=config.account_id,
        ),
        f"{queue.label} archive verification",
    )
    metadata = head_response.get("Metadata")
    if (
        not isinstance(metadata, dict)
        or head_response.get("ContentLength") != len(body)
        or head_response.get("ChecksumSHA256") != checksum
        or metadata.get("archive-sha256") != digest
        or head_response.get("ObjectLockMode") not in ("GOVERNANCE", "COMPLIANCE")
        or not _future_retention(head_response.get("ObjectLockRetainUntilDate"))
    ):
        raise ArchiveError(f"{queue.label} archive verification failed")
    _require_success(
        sqs_client.delete_message(
            QueueUrl=queue.url, ReceiptHandle=message["ReceiptHandle"]
        ),
        f"{queue.label} message deletion",
    )
    return {"archive_key": key, "sha256": digest, "version_id": version_id}
def execute(config, sqs_client, s3_client, lambda_client, cloudwatch_client, sts_client):
    _check_live_identity(sts_client, config)
    _check_object_lock(s3_client, config)
    for queue in config.queues:
        _check_producers(lambda_client, cloudwatch_client, queue)

    archived = []
    overall_status = "PASS"
    for queue in config.queues:
        evidence = []
        empty_receives = 0
        batches = 0
        while empty_receives < EMPTY_RECEIVE_CONFIRMATIONS:
            batches += 1
            if batches > MAX_RECEIVE_BATCHES:
                raise ArchiveError(f"{queue.label} receive confirmation limit exceeded")
            _check_producers(lambda_client, cloudwatch_client, queue)
            response = _require_success(
                sqs_client.receive_message(
                    QueueUrl=queue.url,
                    MaxNumberOfMessages=10,
                    WaitTimeSeconds=20,
                    VisibilityTimeout=300,
                    AttributeNames=["All"],
                    MessageAttributeNames=["All"],
                ),
                f"{queue.label} message receive",
            )
            messages = response.get("Messages", [])
            if not isinstance(messages, list):
                raise ArchiveError(f"{queue.label} receive response is incomplete")
            if not messages:
                empty_receives += 1
                continue
            empty_receives = 0
            for message in messages:
                if not isinstance(message, dict):
                    raise ArchiveError(f"{queue.label} receive response is incomplete")
                evidence.append(
                    _archive_and_delete(config, queue, message, sqs_client, s3_client)
                )
        counts = _queue_counts(sqs_client, config, queue)
        queue_status = "PASS" if all(value == 0 for value in counts.values()) else "PENDING"
        if queue_status != "PASS":
            overall_status = "PENDING"
        archived.append(
            {
                "queue": queue.label,
                "status": queue_status,
                "archived": len(evidence),
                "evidence": evidence,
                "counts": counts,
                "empty_confirmed": True,
                "consecutive_empty_receives": empty_receives,
            }
        )
    return {"mode": "execute", "status": overall_status, "queues": archived}
def _parser():
    parser = argparse.ArgumentParser(
        description="Inspect or archive the exact production immutable-audit DLQs."
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--inspect", action="store_true", help="read-only health inspection")
    mode.add_argument(
        "--execute",
        action="store_true",
        help="archive, verify, and delete each source message",
    )
    parser.add_argument(
        "--terraform-output-json",
        type=Path,
        default=DEFAULT_TERRAFORM_OUTPUT,
        help="bounded terraform output -json file used for the fixed allowlist",
    )
    parser.add_argument(
        "--bucket",
        help="validated archive bucket override; defaults to the Terraform output",
    )
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    try:
        config = load_config(args.terraform_output_json, args.bucket)
        session = boto3.Session(region_name=config.region)
        clients = (
            session.client("sqs"),
            session.client("s3"),
            session.client("lambda"),
            session.client("cloudwatch"),
            session.client("sts"),
        )
        result = inspect(config, *clients) if args.inspect else execute(config, *clients)
        print(json.dumps(result, sort_keys=True))
        return 0 if result["status"] == "PASS" else 2
    except ArchiveError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:
        print("ERROR: unexpected AWS or local operation failure", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())


# Change trail: @hungxqt - 2026-07-29 - Added fail-closed immutable archival and verified deletion for production audit DLQs.
