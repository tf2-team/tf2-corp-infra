import base64
import hashlib
import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError


CONFIG = Config(
    retries={"total_max_attempts": 3, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=60,
)

dynamodb = boto3.client("dynamodb", config=CONFIG)
kms = boto3.client("kms", config=CONFIG)
s3 = boto3.client("s3", config=CONFIG)


CODE_REVISION = "checkpoint-fix-v2"


def _parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _floor_to_window(value, minutes):
    minute = (value.minute // minutes) * minutes
    return value.replace(minute=minute, second=0, microsecond=0)


def _iso(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _canonical_json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _hash_s3_object(bucket, key):
    digest = hashlib.sha256()
    response = s3.get_object(Bucket=bucket, Key=key)
    with response["Body"] as body:
        for chunk in iter(lambda: body.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _candidate_hour_prefixes(raw_prefix, cluster_name, window_start, window_end):
    current = window_start.replace(minute=0, second=0, microsecond=0)
    final = (window_end - timedelta(seconds=1)).replace(minute=0, second=0, microsecond=0)
    prefixes = []
    while current <= final:
        prefixes.append(
            (
                f"{raw_prefix.rstrip('/')}/cluster={cluster_name}/"
                f"year={current:%Y}/month={current:%m}/day={current:%d}/hour={current:%H}/"
            )
        )
        current += timedelta(hours=1)
    return prefixes


def _list_window_objects(bucket, raw_prefix, cluster_name, window_start, window_end):
    objects = []
    paginator = s3.get_paginator("list_objects_v2")
    for prefix in _candidate_hour_prefixes(raw_prefix, cluster_name, window_start, window_end):
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for item in page.get("Contents", []):
                key = item["Key"]
                last_modified = item["LastModified"].astimezone(timezone.utc)
                if key.endswith("/") or last_modified < window_start or last_modified >= window_end:
                    continue
                objects.append(
                    {
                        "bucket": bucket,
                        "key": key,
                        "last_modified": _iso(last_modified),
                        "size": item["Size"],
                        "etag": item["ETag"].strip('"'),
                    }
                )
    return sorted(objects, key=lambda item: item["key"])


def _get_checkpoint(table_name, chain_id):
    response = dynamodb.get_item(
        TableName=table_name,
        Key={"chain_id": {"S": chain_id}},
        ConsistentRead=True,
    )
    return response.get("Item")


def _put_manifest(bucket, key, manifest):
    body = _canonical_json_bytes(manifest)
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=body,
        ContentType="application/json",
        ChecksumSHA256=base64.b64encode(hashlib.sha256(body).digest()).decode("ascii"),
    )


def _update_checkpoint(table_name, chain_id, window_start, window_end, previous_hash, manifest_hash, manifest_key):
    expression_names = {"#status": "status"}
    expression_values = {
        ":window_start": {"S": _iso(window_start)},
        ":window_end": {"S": _iso(window_end)},
        ":manifest_hash": {"S": manifest_hash},
        ":manifest_key": {"S": manifest_key},
        ":status": {"S": "SEALED"},
        ":updated_at": {"S": _iso(datetime.now(timezone.utc))},
    }
    if previous_hash:
        condition = "previous_manifest_hash = :previous_hash"
        expression_values[":previous_hash"] = {"S": previous_hash}
    else:
        condition = "attribute_not_exists(chain_id)"

    dynamodb.update_item(
        TableName=table_name,
        Key={"chain_id": {"S": chain_id}},
        UpdateExpression=(
            "SET last_window_start = :window_start, "
            "last_window_end = :window_end, "
            "previous_manifest_hash = :manifest_hash, "
            "previous_manifest_key = :manifest_key, "
            "#status = :status, "
            "updated_at = :updated_at"
        ),
        ConditionExpression=condition,
        ExpressionAttributeNames=expression_names,
        ExpressionAttributeValues=expression_values,
    )


def _window_from_event(event):
    if event.get("window_start") and event.get("window_end"):
        return _parse_time(event["window_start"]), _parse_time(event["window_end"])

    window_minutes = int(os.environ["WINDOW_MINUTES"])
    delay_minutes = int(os.environ["SEALING_DELAY_MINUTES"])
    event_time = _parse_time(event["time"]) if event.get("time") else datetime.now(timezone.utc)
    window_end = _floor_to_window(event_time - timedelta(minutes=delay_minutes), window_minutes)
    window_start = window_end - timedelta(minutes=window_minutes)
    return window_start, window_end


def handler(event, _context):
    bucket = os.environ["ARCHIVE_BUCKET"]
    chain_id = os.environ["CHAIN_ID"]
    cluster_name = os.environ["CLUSTER_NAME"]
    manifest_prefix = os.environ["MANIFEST_PREFIX"].strip("/")
    raw_prefix = os.environ["RAW_PREFIX"].strip("/")
    table_name = os.environ["CHECKPOINT_TABLE_NAME"]

    window_start, window_end = _window_from_event(event or {})
    if window_end <= window_start:
        raise ValueError("window_end must be after window_start")

    checkpoint = _get_checkpoint(table_name, chain_id)
    previous_hash = checkpoint.get("previous_manifest_hash", {}).get("S", "") if checkpoint else ""
    previous_key = checkpoint.get("previous_manifest_key", {}).get("S", "") if checkpoint else ""
    last_window_end = checkpoint.get("last_window_end", {}).get("S", "") if checkpoint else ""
    if last_window_end and _parse_time(last_window_end) >= window_end:
        result = {
            "status": "SKIPPED",
            "code_revision": CODE_REVISION,
            "reason": "window_already_sealed",
            "chain_id": chain_id,
            "window_start": _iso(window_start),
            "window_end": _iso(window_end),
            "last_window_end": last_window_end,
        }
        print(json.dumps(result, sort_keys=True))
        return result
    if last_window_end and _parse_time(last_window_end) < window_start:
        window_start = _parse_time(last_window_end)
        window_end = window_start + timedelta(minutes=int(os.environ["WINDOW_MINUTES"]))

    raw_objects = _list_window_objects(bucket, raw_prefix, cluster_name, window_start, window_end)
    hashed_objects = []
    for item in raw_objects:
        hashed_objects.append({**item, "sha256": _hash_s3_object(bucket, item["key"])})

    unsigned_manifest = {
        "schema_version": "2026-07-21",
        "chain_id": chain_id,
        "window_start": _iso(window_start),
        "window_end": _iso(window_end),
        "sealed_at": _iso(datetime.now(timezone.utc)),
        "raw_objects": hashed_objects,
        "raw_object_count": len(hashed_objects),
        "previous_manifest_hash": previous_hash,
        "previous_manifest_key": previous_key,
        "kms_key_id": os.environ["SIGNING_KEY_ID"],
        "signature_algorithm": "ECDSA_SHA_256",
    }
    manifest_digest = hashlib.sha256(_canonical_json_bytes(unsigned_manifest)).digest()
    manifest_hash = manifest_digest.hex()
    signature_response = kms.sign(
        KeyId=os.environ["SIGNING_KEY_ID"],
        Message=manifest_digest,
        MessageType="DIGEST",
        SigningAlgorithm="ECDSA_SHA_256",
    )
    manifest = {
        **unsigned_manifest,
        "manifest_hash": manifest_hash,
        "signature": base64.b64encode(signature_response["Signature"]).decode("ascii"),
    }
    manifest_key = (
        f"{manifest_prefix}/chain={chain_id}/"
        f"year={window_start:%Y}/month={window_start:%m}/day={window_start:%d}/"
        f"{window_start:%H%M}-{window_end:%H%M}-{manifest_hash[:16]}.json"
    )

    try:
        _put_manifest(bucket, manifest_key, manifest)
        _update_checkpoint(table_name, chain_id, window_start, window_end, previous_hash, manifest_hash, manifest_key)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            print(
                json.dumps(
                    {
                        "status": "SKIPPED",
                        "code_revision": CODE_REVISION,
                        "reason": "checkpoint_changed",
                        "chain_id": chain_id,
                        "window_start": _iso(window_start),
                        "window_end": _iso(window_end),
                    },
                    sort_keys=True,
                )
            )
            return {"status": "SKIPPED", "reason": "checkpoint_changed"}
        raise

    result = {
        "status": "SEALED",
        "code_revision": CODE_REVISION,
        "chain_id": chain_id,
        "window_start": _iso(window_start),
        "window_end": _iso(window_end),
        "raw_object_count": len(hashed_objects),
        "manifest_hash": manifest_hash,
        "manifest_key": manifest_key,
    }
    print(json.dumps(result, sort_keys=True))
    return result
