import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "immutable_audit_health_check.py"
CHECK_NAMES = [
    "_check_cloudtrail",
    "_check_s3",
    "_check_kms",
    "_check_eventbridge",
    "_check_validation_reports",
    "_check_k8s_sealer_checkpoint",
    "_check_audit_dlqs",
    "_check_sns",
    "_check_logs",
    "_check_discord_secret",
]


def _load_module():
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = mock.Mock(
        side_effect=lambda service, config=None: mock.Mock(name=service)
    )

    fake_botocore = types.ModuleType("botocore")
    fake_botocore_config = types.ModuleType("botocore.config")
    fake_botocore_config.Config = mock.Mock(return_value=object())
    fake_botocore.config = fake_botocore_config

    spec = importlib.util.spec_from_file_location(
        "immutable_audit_health_check_under_test", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(
        sys.modules,
        {
            "boto3": fake_boto3,
            "botocore": fake_botocore,
            "botocore.config": fake_botocore_config,
        },
    ):
        spec.loader.exec_module(module)
    return module


class ImmutableAuditHealthCheckTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = _load_module()

    def setUp(self):
        self.check_patchers = [
            mock.patch.object(self.module, check_name) for check_name in CHECK_NAMES
        ]
        self.checks = {
            name: patcher.start()
            for name, patcher in zip(CHECK_NAMES, self.check_patchers)
        }
        for name, check in self.checks.items():
            check.__name__ = name
        self.addCleanup(self._stop_check_patchers)
        self.metric_patcher = mock.patch.object(self.module, "_put_health_metric")
        self.put_health_metric = self.metric_patcher.start()
        self.addCleanup(self.metric_patcher.stop)

    def _stop_check_patchers(self):
        for patcher in reversed(self.check_patchers):
            patcher.stop()

    def test_pass_publishes_healthy_metric(self):
        result = self.module.handler({}, None)

        self.assertEqual({"status": "PASS"}, result)
        self.put_health_metric.assert_called_once_with(1)

    def test_detected_drift_returns_fail_and_publishes_unhealthy_metric(self):
        self.checks["_check_cloudtrail"].side_effect = lambda errors: errors.append(
            "expected control drift"
        )

        result = self.module.handler({}, None)

        self.assertEqual(
            {"status": "FAIL", "errors": ["expected control drift"]},
            result,
        )
        self.put_health_metric.assert_called_once_with(0)

    def test_individual_check_exception_is_converted_to_fail(self):
        self.checks["_check_cloudtrail"].side_effect = RuntimeError(
            "control API unavailable"
        )

        result = self.module.handler({}, None)

        self.assertEqual("FAIL", result["status"])
        self.assertEqual(
            ["_check_cloudtrail failed: control API unavailable"],
            result["errors"],
        )
        self.put_health_metric.assert_called_once_with(0)

    def test_healthy_metric_publication_exception_propagates(self):
        self.put_health_metric.side_effect = RuntimeError(
            "metric publication failed"
        )

        with self.assertRaisesRegex(RuntimeError, "metric publication failed"):
            self.module.handler({}, None)

    def test_unhealthy_metric_publication_exception_propagates(self):
        self.checks["_check_cloudtrail"].side_effect = lambda errors: errors.append(
            "expected control drift"
        )
        self.put_health_metric.side_effect = RuntimeError(
            "metric publication failed"
        )

        with self.assertRaisesRegex(RuntimeError, "metric publication failed"):
            self.module.handler({}, None)


class ImmutableAuditHealthCheckEventBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = _load_module()

    def test_scheduler_schedule_must_be_enabled_and_targeted(self):
        fake_events = mock.Mock()
        fake_events.describe_rule.return_value = {"State": "ENABLED"}
        fake_events.list_targets_by_rule.return_value = {
            "Targets": [{"Arn": "arn:aws:sns:us-east-1:123456789012:topic"}],
        }
        fake_scheduler = mock.Mock()
        fake_scheduler.get_schedule.return_value = {
            "State": "DISABLED",
            "Target": {},
        }
        env = {
            "TAMPER_RULE_NAMES": "[]",
            "TAMPER_TOPIC_RULE_NAMES": "[]",
            "TAMPER_TOPIC_ARN": "arn:aws:sns:us-east-1:123456789012:topic",
            "SCHEDULED_RULE_NAMES": "[]",
            "SCHEDULED_SCHEDULE_NAMES": '["audit-health"]',
            "SCHEDULE_GROUP_NAME": "audit-schedules",
        }

        errors = []
        with (
            mock.patch.object(self.module, "events", fake_events),
            mock.patch.object(self.module, "scheduler", fake_scheduler),
            mock.patch.dict(self.module.os.environ, env, clear=False),
        ):
            self.module._check_eventbridge(errors)

        fake_scheduler.get_schedule.assert_called_once_with(
            GroupName="audit-schedules",
            Name="audit-health",
        )
        self.assertEqual(
            [
                "EventBridge schedule is not ENABLED: audit-health",
                "EventBridge schedule has no target: audit-health",
            ],
            errors,
        )

# Change trail: @hungxqt - 2026-07-30 - Covered EventBridge Scheduler health drift checks.
