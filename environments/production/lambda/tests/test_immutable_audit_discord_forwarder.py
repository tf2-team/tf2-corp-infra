import importlib.util
import json
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1] / "immutable_audit_discord_forwarder.py"
)


def _load_module():
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = mock.Mock(return_value=mock.Mock(name="secretsmanager"))

    spec = importlib.util.spec_from_file_location(
        "immutable_audit_discord_forwarder_under_test", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, {"boto3": fake_boto3}):
        spec.loader.exec_module(module)
    return module


def _alert_ready_envelope():
    return {
        "schema_version": "audit-alert-ready/v1",
        "event": "audit_alert_ready",
        "source_type": "cloudwatch_logs",
        "parser_phase": "phase_6_evidence_ttd",
        "normalized_event": {
            "rule_id": "k8s.exec.high_risk",
            "severity": "high",
            "actor": "test-actor",
            "action": "create",
            "namespace": "test-namespace",
            "resource": "pods/exec",
            "source_ip": "192.0.2.10",
            "event_time_utc": "2026-07-30T01:00:00Z",
        },
        "evidence": {
            "rule_id": "k8s.exec.high_risk",
            "severity": "high",
            "status": "alert_ready",
            "event_time_utc": "2026-07-30T01:00:00Z",
            "time_to_alert_ready_seconds": 2.5,
        },
        "alert_message": "content intentionally not used by the forwarder",
    }


class ImmutableAuditDiscordForwarderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = _load_module()

    def test_recognizes_production_alert_ready_contract(self):
        contract = self.module._message_contract(_alert_ready_envelope())

        self.assertEqual("audit_alert_ready_v1", contract)

    def test_formats_alert_ready_contract_from_normalized_fields(self):
        payload = self.module._format_message(_alert_ready_envelope())
        embed = payload["embeds"][0]
        fields = {field["name"]: field["value"] for field in embed["fields"]}

        self.assertEqual("K8s audit alert: k8s.exec.high_risk", embed["title"])
        self.assertEqual("high", fields["Severity"])
        self.assertEqual("test-actor", fields["Actor"])
        self.assertEqual("test-namespace", fields["Namespace"])

    def test_handler_delivers_alert_ready_without_batch_failure(self):
        event = {
            "Records": [
                {
                    "messageId": "message-1",
                    "body": json.dumps(_alert_ready_envelope()),
                }
            ]
        }

        with (
            mock.patch.object(self.module, "_post_discord") as post_discord,
            mock.patch.object(
                self.module, "_emit_delivery_evidence"
            ) as emit_evidence,
        ):
            result = self.module.handler(event, None)

        self.assertEqual({"batchItemFailures": []}, result)
        post_discord.assert_called_once()
        emit_evidence.assert_called_once_with(
            mock.ANY, "audit_alert_ready_v1", "sent"
        )

    def test_rejects_malformed_alert_ready_envelope(self):
        malformed = _alert_ready_envelope()
        malformed["normalized_event"] = "not-an-object"

        self.assertEqual("unknown", self.module._message_contract(malformed))
        with self.assertRaisesRegex(
            ValueError, "unsupported_audit_alert_message_contract"
        ):
            self.module._format_message(malformed)

    def test_legacy_cloudtrail_contract_remains_supported(self):
        event = {
            "detail-type": "AWS API Call via CloudTrail",
            "detail": {"eventName": "StopLogging"},
        }

        self.assertEqual(
            "cloudtrail_eventbridge", self.module._message_contract(event)
        )


# Change trail: @hungxqt - 2026-07-30 - Regress the production
# audit-alert-ready/v1 envelope without exposing audit payloads.
