import importlib.util
import io
import json
import sys
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "archive-immutable-audit-dlqs.py"


def _load_module():
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.Session = mock.Mock()
    spec = importlib.util.spec_from_file_location(
        "archive_immutable_audit_dlqs_under_test", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {"boto3": fake_boto3}):
        sys.modules[spec.name] = module
        try:
            spec.loader.exec_module(module)
        finally:
            sys.modules.pop(spec.name, None)
    return module


def _success(**values):
    return {"ResponseMetadata": {"HTTPStatusCode": 200}, **values}


def _outputs():
    values = {
        "immutable_audit_k8s_raw_archive_bucket_name": "techx-prod-audit-archive",
        "immutable_audit_discord_dlq_url": (
            "https://sqs.us-east-1.amazonaws.com/493499579600/"
            "techx-prod-cloudtrail-discord-dlq"
        ),
        "immutable_audit_health_lambda_dlq_url": (
            "https://sqs.us-east-1.amazonaws.com/493499579600/"
            "techx-prod-mandate12-immutable-audit-health-lambda-dlq"
        ),
        "immutable_audit_k8s_sealer_dlq_url": (
            "https://sqs.us-east-1.amazonaws.com/493499579600/"
            "techx-prod-k8s-audit-sealer-dlq"
        ),
        "immutable_audit_validation_dlq_url": (
            "https://sqs.us-east-1.amazonaws.com/493499579600/"
            "techx-prod-audit-validation-dlq"
        ),
        "immutable_audit_health_check_lambda_name": (
            "techx-prod-mandate12-immutable-audit-health-check"
        ),
        "immutable_audit_k8s_sealer_lambda_name": "techx-prod-k8s-audit-sealer",
        "immutable_audit_cloudtrail_validator_lambda_name": (
            "techx-prod-cloudtrail-validator"
        ),
        "immutable_audit_k8s_manifest_validator_lambda_name": (
            "techx-prod-k8s-manifest-validator"
        ),
        "immutable_audit_validation_alarm_names": {
            "cloudtrail": "techx-prod-cloudtrail-validator-fail",
            "k8s_manifests": "techx-prod-k8s-manifest-validator-fail",
        },
        "immutable_audit_dlq_producer_alarm_names": {
            "discord_errors": "techx-prod-cloudtrail-discord-forwarder-errors",
            "discord_throttles": "techx-prod-cloudtrail-discord-forwarder-throttles",
            "health_check_errors": "techx-prod-immutable-audit-health-check-errors",
            "k8s_sealer_errors": "techx-prod-k8s-audit-sealer-errors",
            "cloudtrail_validation": "techx-prod-cloudtrail-validator-fail",
            "k8s_manifest_validation": "techx-prod-k8s-manifest-validator-fail",
        },
    }
    return {key: {"value": value} for key, value in values.items()}


class ArchiveImmutableAuditDlqsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = _load_module()

    def setUp(self):
        self.sqs = mock.Mock()
        self.s3 = mock.Mock()
        self.lambda_client = mock.Mock()
        self.cloudwatch = mock.Mock()
        self.sts = mock.Mock()
        self.sts.get_caller_identity.return_value = _success(Account="493499579600")
        self.s3.get_object_lock_configuration.return_value = _success(
            ObjectLockConfiguration={
                "ObjectLockEnabled": "Enabled",
                "Rule": {
                    "DefaultRetention": {"Mode": "COMPLIANCE", "Days": 30}
                },
            }
        )
        self.lambda_client.get_function_configuration.side_effect = (
            lambda FunctionName: _success(
                FunctionName=FunctionName,
                State="Active",
                LastUpdateStatus="Successful",
            )
        )
        self.cloudwatch.describe_alarms.side_effect = lambda AlarmNames: _success(
            MetricAlarms=[
                {"AlarmName": name, "StateValue": "OK"} for name in AlarmNames
            ]
        )

        def queue_attributes(QueueUrl, AttributeNames):
            queue_name = QueueUrl.rstrip("/").split("/")[-1]
            return _success(
                Attributes={
                    "ApproximateNumberOfMessages": "0",
                    "ApproximateNumberOfMessagesNotVisible": "0",
                    "ApproximateNumberOfMessagesDelayed": "0",
                    "QueueArn": f"arn:aws:sqs:us-east-1:493499579600:{queue_name}",
                }
            )

        self.sqs.get_queue_attributes.side_effect = queue_attributes

    def _config(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(_outputs()), encoding="utf-8")
            return self.module.load_config(path)

    def test_inspect_is_read_only_and_reports_only_safe_counts(self):
        result = self.module.inspect(
            self._config(), self.sqs, self.s3, self.lambda_client, self.cloudwatch, self.sts
        )

        self.assertEqual("PASS", result["status"])
        self.assertEqual(
            ["discord", "health-check", "k8s-sealer", "validation"],
            [item["queue"] for item in result["queues"]],
        )
        self.sqs.receive_message.assert_not_called()
        self.sqs.delete_message.assert_not_called()
        self.s3.put_object.assert_not_called()
        self.assertNotIn("Body", json.dumps(result))

    def test_execute_uses_archive_head_delete_sequence(self):
        config = self._config()
        message = {
            "MessageId": "message-1",
            "ReceiptHandle": "receipt-secret",
            "Body": "sensitive-body",
            "Attributes": {"SentTimestamp": "1"},
            "MessageAttributes": {"kind": {"DataType": "String", "StringValue": "x"}},
        }
        receive_results = iter(
            [
                _success(Messages=[message]),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
            ]
        )
        self.sqs.receive_message.side_effect = lambda **_kwargs: next(receive_results)
        parent = mock.Mock()
        parent.attach_mock(self.s3.put_object, "put")
        parent.attach_mock(self.s3.head_object, "head")
        parent.attach_mock(self.sqs.delete_message, "delete")
        self.s3.put_object.return_value = _success(VersionId="version-1")

        def head_object(**_kwargs):
            put_kwargs = self.s3.put_object.call_args.kwargs
            return _success(
                ContentLength=len(put_kwargs["Body"]),
                ChecksumSHA256=put_kwargs["ChecksumSHA256"],
                Metadata=put_kwargs["Metadata"],
                ObjectLockMode="COMPLIANCE",
                ObjectLockRetainUntilDate=datetime.now(timezone.utc)
                + timedelta(days=30),
            )

        self.s3.head_object.side_effect = head_object
        self.sqs.delete_message.return_value = _success()

        result = self.module.execute(
            config, self.sqs, self.s3, self.lambda_client, self.cloudwatch, self.sts
        )

        self.assertEqual(1, result["queues"][0]["archived"])
        self.assertTrue(result["queues"][0]["empty_confirmed"])
        self.assertEqual(["put", "head", "delete"], [call[0] for call in parent.mock_calls])
        archived = json.loads(self.s3.put_object.call_args.kwargs["Body"])
        self.assertEqual("sensitive-body", archived["body"])
        self.assertEqual({"SentTimestamp": "1"}, archived["system_attributes"])
        self.assertEqual(message["MessageAttributes"], archived["message_attributes"])
        self.sqs.send_message.assert_not_called()
        self.sqs.send_message_batch.assert_not_called()
        self.sqs.start_message_move_task.assert_not_called()

    def test_verification_failure_never_deletes_message(self):
        config = self._config()
        self.sqs.receive_message.return_value = _success(
            Messages=[
                {
                    "MessageId": "message-1",
                    "ReceiptHandle": "receipt-secret",
                    "Body": "sensitive-body",
                    "Attributes": {},
                    "MessageAttributes": {},
                }
            ]
        )
        self.s3.put_object.return_value = _success(VersionId="version-1")
        self.s3.head_object.return_value = _success(
            ContentLength=0,
            ChecksumSHA256="wrong",
            Metadata={},
            ObjectLockMode="COMPLIANCE",
            ObjectLockRetainUntilDate=datetime.now(timezone.utc)
                + timedelta(days=30),
        )

        with self.assertRaisesRegex(
            self.module.ArchiveError, "archive verification failed"
        ):
            self.module.execute(
                config, self.sqs, self.s3, self.lambda_client,
                self.cloudwatch, self.sts
            )

        self.sqs.delete_message.assert_not_called()

    def test_expired_retention_never_deletes_message(self):
        config = self._config()
        self.sqs.receive_message.return_value = _success(
            Messages=[
                {
                    "MessageId": "message-1",
                    "ReceiptHandle": "receipt-secret",
                    "Body": "sensitive-body",
                    "Attributes": {},
                    "MessageAttributes": {},
                }
            ]
        )
        self.s3.put_object.return_value = _success(VersionId="version-1")

        def head_object(**_kwargs):
            put_kwargs = self.s3.put_object.call_args.kwargs
            return _success(
                ContentLength=len(put_kwargs["Body"]),
                ChecksumSHA256=put_kwargs["ChecksumSHA256"],
                Metadata=put_kwargs["Metadata"],
                ObjectLockMode="COMPLIANCE",
                ObjectLockRetainUntilDate=datetime.now(timezone.utc)
                - timedelta(seconds=1),
            )

        self.s3.head_object.side_effect = head_object

        with self.assertRaisesRegex(
            self.module.ArchiveError, "archive verification failed"
        ):
            self.module.execute(
                config, self.sqs, self.s3, self.lambda_client,
                self.cloudwatch, self.sts
            )

        self.sqs.delete_message.assert_not_called()

    def test_partial_message_attributes_never_archive_or_delete(self):
        config = self._config()
        self.sqs.receive_message.return_value = _success(
            Messages=[
                {
                    "MessageId": "message-1",
                    "ReceiptHandle": "receipt-secret",
                    "Body": "sensitive-body",
                    "Attributes": {},
                }
            ]
        )

        with self.assertRaisesRegex(self.module.ArchiveError, "incomplete"):
            self.module.execute(
                config, self.sqs, self.s3, self.lambda_client,
                self.cloudwatch, self.sts
            )

        self.s3.put_object.assert_not_called()
        self.sqs.delete_message.assert_not_called()

    def test_transient_empty_receive_does_not_end_drain(self):
        config = self._config()
        message = {
            "MessageId": "message-1",
            "ReceiptHandle": "receipt-secret",
            "Body": "sensitive-body",
            "Attributes": {},
            "MessageAttributes": {},
        }
        self.sqs.receive_message.side_effect = iter(
            [
                _success(),
                _success(Messages=[message]),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
                _success(),
            ]
        )
        self.s3.put_object.return_value = _success(VersionId="version-1")

        def head_object(**_kwargs):
            put_kwargs = self.s3.put_object.call_args.kwargs
            return _success(
                ContentLength=len(put_kwargs["Body"]),
                ChecksumSHA256=put_kwargs["ChecksumSHA256"],
                Metadata=put_kwargs["Metadata"],
                ObjectLockMode="COMPLIANCE",
                ObjectLockRetainUntilDate=datetime.now(timezone.utc)
                + timedelta(days=30),
            )

        self.s3.head_object.side_effect = head_object
        self.sqs.delete_message.return_value = _success()

        result = self.module.execute(
            config, self.sqs, self.s3, self.lambda_client, self.cloudwatch, self.sts
        )

        self.assertEqual(1, result["queues"][0]["archived"])
        self.assertEqual(
            self.module.EMPTY_RECEIVE_CONFIRMATIONS,
            result["queues"][0]["consecutive_empty_receives"],
        )
    def test_config_is_an_exact_four_queue_allowlist(self):
        config = self._config()

        self.assertEqual(
            self.module.QUEUE_OUTPUT_KEYS,
            tuple(queue.output_key for queue in config.queues),
        )
        self.assertFalse(
            any(
                action.option_strings == ["--queue"]
                for action in self.module._parser()._actions
            )
        )

    def test_unknown_queue_substitution_is_rejected(self):
        outputs = _outputs()
        outputs["immutable_audit_discord_dlq_url"]["value"] = (
            "https://sqs.us-east-1.amazonaws.com/493499579600/arbitrary-dlq"
        )
        with TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(outputs), encoding="utf-8")
            with self.assertRaisesRegex(
                self.module.ArchiveError, "production naming contract"
            ):
                self.module.load_config(path)

    def test_health_dlq_substitution_is_rejected(self):
        outputs = _outputs()
        outputs["immutable_audit_health_lambda_dlq_url"]["value"] = (
            "https://sqs.us-east-1.amazonaws.com/493499579600/arbitrary-health-dlq"
        )
        with TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(outputs), encoding="utf-8")
            with self.assertRaisesRegex(
                self.module.ArchiveError, "health-check DLQ"
            ):
                self.module.load_config(path)

    def test_nonproduction_account_outputs_are_rejected(self):
        outputs = _outputs()
        for key in self.module.QUEUE_OUTPUT_KEYS:
            outputs[key]["value"] = outputs[key]["value"].replace(
                "493499579600", "123456789012"
            )
        with TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(outputs), encoding="utf-8")
            with self.assertRaisesRegex(self.module.ArchiveError, "pinned production"):
                self.module.load_config(path)

    def test_nonproduction_region_outputs_are_rejected(self):
        outputs = _outputs()
        for key in self.module.QUEUE_OUTPUT_KEYS:
            outputs[key]["value"] = outputs[key]["value"].replace(
                "us-east-1", "us-west-2"
            )
        with TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(outputs), encoding="utf-8")
            with self.assertRaisesRegex(self.module.ArchiveError, "pinned production"):
                self.module.load_config(path)
    def test_producer_health_failure_prevents_receive_and_mutation(self):
        self.lambda_client.get_function_configuration.side_effect = None
        self.lambda_client.get_function_configuration.return_value = _success(
            FunctionName="unexpected",
            State="Failed",
            LastUpdateStatus="Failed",
        )

        with self.assertRaisesRegex(self.module.ArchiveError, "not healthy"):
            self.module.execute(
                self._config(), self.sqs, self.s3, self.lambda_client, self.cloudwatch, self.sts
            )

        self.sqs.receive_message.assert_not_called()
        self.s3.put_object.assert_not_called()
        self.sqs.delete_message.assert_not_called()

    def test_inspect_never_calls_replay_apis(self):
        self.module.inspect(
            self._config(), self.sqs, self.s3, self.lambda_client, self.cloudwatch, self.sts
        )

        self.sqs.send_message.assert_not_called()
        self.sqs.send_message_batch.assert_not_called()
        self.sqs.start_message_move_task.assert_not_called()

    def test_any_producer_alarm_failure_prevents_receive_and_mutation(self):
        self.cloudwatch.describe_alarms.side_effect = None
        self.cloudwatch.describe_alarms.return_value = _success(
            MetricAlarms=[
                {
                    "AlarmName": "techx-prod-cloudtrail-discord-forwarder-errors",
                    "StateValue": "ALARM",
                },
                {
                    "AlarmName": "techx-prod-cloudtrail-discord-forwarder-throttles",
                    "StateValue": "OK",
                },
            ]
        )

        with self.assertRaisesRegex(self.module.ArchiveError, "alarms are not healthy"):
            self.module.execute(
                self._config(), self.sqs, self.s3, self.lambda_client,
                self.cloudwatch, self.sts
            )

        self.sqs.receive_message.assert_not_called()
        self.s3.put_object.assert_not_called()
    def test_cross_account_identity_prevents_receive_and_mutation(self):
        self.sts.get_caller_identity.return_value = _success(Account="999999999999")

        with self.assertRaisesRegex(self.module.ArchiveError, "caller account"):
            self.module.execute(
                self._config(), self.sqs, self.s3, self.lambda_client,
                self.cloudwatch, self.sts
            )

        self.sqs.receive_message.assert_not_called()
        self.s3.put_object.assert_not_called()

    def test_nonzero_inflight_count_returns_pending(self):
        config = self._config()
        self.sqs.receive_message.side_effect = [_success()] * 10

        def queue_attributes(QueueUrl, AttributeNames):
            queue_name = QueueUrl.rstrip("/").split("/")[-1]
            return _success(
                Attributes={
                    "ApproximateNumberOfMessages": "0",
                    "ApproximateNumberOfMessagesNotVisible": "1",
                    "ApproximateNumberOfMessagesDelayed": "0",
                    "QueueArn": f"arn:aws:sqs:us-east-1:493499579600:{queue_name}",
                }
            )

        self.sqs.get_queue_attributes.side_effect = queue_attributes
        result = self.module.execute(
            config, self.sqs, self.s3, self.lambda_client,
            self.cloudwatch, self.sts
        )

        self.assertEqual("PENDING", result["status"])
        self.assertTrue(all(item["status"] == "PENDING" for item in result["queues"]))

    def test_bucket_override_must_equal_terraform_output(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "outputs.json"
            path.write_text(json.dumps(_outputs()), encoding="utf-8")
            with self.assertRaisesRegex(self.module.ArchiveError, "must match"):
                self.module.load_config(path, "another-valid-bucket")

    def test_binary_message_attributes_are_preserved_as_base64(self):
        queue = self._config().queues[0]
        message = {
            "MessageId": "message-1",
            "ReceiptHandle": "receipt-secret",
            "Body": "body",
            "Attributes": {},
            "MessageAttributes": {
                "binary": {"DataType": "Binary", "BinaryValue": b"evidence"}
            },
        }

        body, _digest, _key = self.module._archive_document(queue, message)
        archived = json.loads(body)

        self.assertEqual(
            {"base64": "ZXZpZGVuY2U="},
            archived["message_attributes"]["binary"]["BinaryValue"],
        )
    def test_cli_error_output_never_exposes_message_content(self):
        stderr = io.StringIO()
        stdout = io.StringIO()
        with mock.patch.object(
            self.module, "load_config", side_effect=RuntimeError("sensitive-body")
        ), redirect_stderr(stderr), redirect_stdout(stdout):
            exit_code = self.module.main(["--inspect"])

        self.assertEqual(1, exit_code)
        self.assertEqual("", stdout.getvalue())
        self.assertNotIn("sensitive-body", stderr.getvalue())
        self.assertEqual(
            "ERROR: unexpected AWS or local operation failure\n", stderr.getvalue()
        )


# Change trail: @hungxqt - 2026-07-30 - Cover the exact four-queue immutable-audit recovery allowlist after MD11 router retirement.
