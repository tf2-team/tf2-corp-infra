import base64
import hashlib
import json
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.config import Config


CONFIG = Config(
    retries={"total_max_attempts": 3, "mode": "adaptive"},
    connect_timeout=5,
    read_timeout=60,
)

cloudwatch = boto3.client("cloudwatch", config=CONFIG)
kms = boto3.client("kms", config=CONFIG)
s3 = boto3.client("s3", config=CONFIG)


def _iso(value):
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def _canonical_json_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _hash_s3_object(bucket, key):
    digest = hashlib.sha256()
    response = s3.get_object(Bucket=bucket, Key=key)
    with response["Body"] as body:
        for chunk in iter(lambda: body.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _list_manifest_objects(bucket, prefix):
    objects = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for item in page.get("Contents", []):
            if item["Key"].endswith(".json"):
                objects.append({"key": item["Key"], "last_modified": item["LastModified"], "size": item["Size"]})
    return sorted(objects, key=lambda item: item["key"])


def _read_json_object(bucket, key):
    response = s3.get_object(Bucket=bucket, Key=key)
    with response["Body"] as body:
        return json.loads(body.read())


def _select_manifest_chain(candidates, expected_initial_previous_hash=None):
    by_previous_hash = {}
    for candidate in candidates:
        previous_hash = candidate["manifest"].get("previous_manifest_hash", "")
        by_previous_hash.setdefault(previous_hash, []).append(candidate)

    for items in by_previous_hash.values():
        items.sort(key=lambda item: (item["window_start"], item["last_modified"], item["key"]))

    start_hash = expected_initial_previous_hash if expected_initial_previous_hash is not None else ""
    frontier = [(start_hash, [], None)]
    best = []
    visited = set()
    while frontier:
        expected_hash, chain, last_window_end = frontier.pop()
        if len(chain) > len(best):
            best = chain
        state = (expected_hash, last_window_end)
        if state in visited:
            continue
        visited.add(state)

        for candidate in by_previous_hash.get(expected_hash, []):
            if any(item["key"] == candidate["key"] for item in chain):
                continue
            if last_window_end is not None and candidate["window_start"] < last_window_end:
                continue
            manifest_hash = candidate["manifest"].get("manifest_hash")
            if not manifest_hash:
                continue
            frontier.append((manifest_hash, [*chain, candidate], candidate["window_end"]))

    return best


def _manifest_digest(manifest):
    unsigned = dict(manifest)
    unsigned.pop("manifest_hash", None)
    unsigned.pop("signature", None)
    return hashlib.sha256(_canonical_json_bytes(unsigned)).digest()


def _verify_manifest(bucket, manifest_key, expected_previous_hash=None):
    manifest = _read_json_object(bucket, manifest_key)
    errors = []
    digest = _manifest_digest(manifest)
    digest_hex = digest.hex()
    if manifest.get("manifest_hash") != digest_hex:
        errors.append("manifest_hash mismatch")
    if expected_previous_hash is not None and manifest.get("previous_manifest_hash", "") != expected_previous_hash:
        errors.append(
            f"previous_manifest_hash mismatch: expected {expected_previous_hash}, got {manifest.get('previous_manifest_hash')}"
        )

    try:
        verify_response = kms.verify(
            KeyId=manifest["kms_key_id"],
            Message=digest,
            MessageType="DIGEST",
            Signature=base64.b64decode(manifest["signature"]),
            SigningAlgorithm=manifest["signature_algorithm"],
        )
        if not verify_response.get("SignatureValid"):
            errors.append("KMS signature invalid")
    except Exception as exc:
        errors.append(f"KMS signature verification failed: {exc}")

    raw_results = []
    for raw_object in manifest.get("raw_objects", []):
        actual_hash = _hash_s3_object(raw_object["bucket"], raw_object["key"])
        ok = actual_hash == raw_object.get("sha256")
        if not ok:
            errors.append(f"raw object hash mismatch: {raw_object['key']}")
        raw_results.append(
            {
                "key": raw_object["key"],
                "expected_sha256": raw_object.get("sha256"),
                "actual_sha256": actual_hash,
                "status": "PASS" if ok else "FAIL",
            }
        )

    return {
        "manifest_key": manifest_key,
        "manifest_hash": manifest.get("manifest_hash"),
        "window_start": manifest.get("window_start"),
        "window_end": manifest.get("window_end"),
        "raw_object_count": len(manifest.get("raw_objects", [])),
        "raw_results": raw_results,
        "status": "PASS" if not errors else "FAIL",
        "errors": errors,
    }


def _put_metric(value):
    cloudwatch.put_metric_data(
        Namespace="TechX/Audit",
        MetricData=[
            {
                "MetricName": "ImmutableAuditK8sManifestValidationPass",
                "Dimensions": [{"Name": "ChainId", "Value": os.environ["CHAIN_ID"]}],
                "Value": value,
                "Unit": "None",
            }
        ],
    )


def _put_report(report):
    timestamp = _parse_time(report["validated_at"])
    key = (
        f"{os.environ['REPORT_PREFIX'].strip('/')}/k8s-manifests/"
        f"year={timestamp:%Y}/month={timestamp:%m}/day={timestamp:%d}/"
        f"{timestamp:%H%M%S}-{report['status'].lower()}.json"
    )
    s3.put_object(
        Bucket=os.environ["ARCHIVE_BUCKET"],
        Key=key,
        Body=_canonical_json_bytes(report),
        ContentType="application/json",
    )
    return key


def _candidate_day_prefixes(manifest_prefix, chain_id, window_start, window_end):
    day = window_start
    prefixes = []
    while day.date() <= window_end.date():
        prefixes.append(
            f"{manifest_prefix.rstrip('/')}/chain={chain_id}/year={day:%Y}/month={day:%m}/day={day:%d}/"
        )
        day += timedelta(days=1)
    return prefixes


def _validate(event):
    now = datetime.now(timezone.utc)
    archive_bucket = os.environ["ARCHIVE_BUCKET"]
    chain_id = os.environ["CHAIN_ID"]
    manifest_prefix = os.environ["MANIFEST_PREFIX"]
    window_end = now - timedelta(minutes=int(os.environ["VALIDATION_DELAY_MINUTES"]))
    window_start = window_end - timedelta(hours=int(os.environ["VALIDATION_LOOKBACK_HOURS"]))
    if event.get("window_start") and event.get("window_end"):
        window_start = _parse_time(event["window_start"])
        window_end = _parse_time(event["window_end"])

    manifests = []
    for prefix in _candidate_day_prefixes(manifest_prefix, chain_id, window_start, window_end):
        manifests.extend(_list_manifest_objects(archive_bucket, prefix))

    candidates = []
    for item in manifests:
        manifest = _read_json_object(archive_bucket, item["key"])
        manifest_start = _parse_time(manifest["window_start"])
        manifest_end = _parse_time(manifest["window_end"])
        if manifest_start >= window_start and manifest_end <= window_end:
            candidates.append(
                {
                    "key": item["key"],
                    "last_modified": item["last_modified"],
                    "manifest": manifest,
                    "window_start": manifest_start,
                    "window_end": manifest_end,
                }
            )

    errors = []
    if not candidates:
        errors.append("No signed K8s audit manifests found in validation lookback")

    previous_hash = event.get("expected_initial_previous_hash")
    selected = _select_manifest_chain(candidates, previous_hash)
    if candidates and not selected:
        errors.append("No continuous K8s audit manifest chain found in validation lookback")

    manifest_results = []
    for candidate in selected:
        manifest_key = candidate["key"]
        result = _verify_manifest(archive_bucket, manifest_key, previous_hash)
        manifest_results.append(result)
        if result["status"] != "PASS":
            errors.extend([f"{manifest_key}: {error}" for error in result["errors"]])
        previous_hash = result.get("manifest_hash") or previous_hash

    report = {
        "schema_version": "2026-07-21",
        "validator": "k8s-manifest-chain",
        "chain_id": chain_id,
        "validated_at": _iso(now),
        "window_start": _iso(window_start),
        "window_end": _iso(window_end),
        "status": "PASS" if not errors else "FAIL",
        "errors": errors,
        "candidate_manifest_count": len(candidates),
        "ignored_manifest_count": max(len(candidates) - len(selected), 0),
        "manifest_count": len(selected),
        "manifest_results": manifest_results,
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
