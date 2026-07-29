import importlib.util
import sys
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "immutable_audit_k8s_sealer.py"


def _load_module():
    fake_boto3 = types.ModuleType("boto3")
    fake_boto3.client = mock.Mock(
        side_effect=lambda service, config=None: mock.Mock(name=service)
    )
    fake_botocore = types.ModuleType("botocore")
    fake_botocore_config = types.ModuleType("botocore.config")
    fake_botocore_exceptions = types.ModuleType("botocore.exceptions")
    fake_botocore_exceptions.ClientError = type("ClientError", (Exception,), {})
    fake_botocore_config.Config = mock.Mock(return_value=object())
    fake_botocore.config = fake_botocore_config
    fake_botocore.exceptions = fake_botocore_exceptions
    spec = importlib.util.spec_from_file_location(
        "immutable_audit_k8s_sealer_under_test", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(
        sys.modules,
        {
            "boto3": fake_boto3,
            "botocore": fake_botocore,
            "botocore.config": fake_botocore_config,
            "botocore.exceptions": fake_botocore_exceptions,
        },
    ):
        spec.loader.exec_module(module)
    return module


class ImmutableAuditK8sSealerCheckpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = _load_module()

    def setUp(self):
        self.module.dynamodb.reset_mock()

    def _update_checkpoint(self, previous_hash):
        self.module._update_checkpoint(
            "checkpoint-table",
            "cluster-chain",
            datetime(2026, 7, 29, 1, 0, tzinfo=timezone.utc),
            datetime(2026, 7, 29, 1, 5, tzinfo=timezone.utc),
            previous_hash,
            "new-manifest-hash",
            "manifests/manifest.json",
        )
        return self.module.dynamodb.update_item.call_args.kwargs

    def test_initial_checkpoint_omits_unused_previous_hash_value(self):
        request = self._update_checkpoint("")

        self.assertEqual("attribute_not_exists(chain_id)", request["ConditionExpression"])
        self.assertNotIn(":previous_hash", request["ExpressionAttributeValues"])

    def test_chained_checkpoint_conditions_on_previous_hash_value(self):
        request = self._update_checkpoint("prior-manifest-hash")

        self.assertEqual(
            "previous_manifest_hash = :previous_hash",
            request["ConditionExpression"],
        )
        self.assertEqual(
            {"S": "prior-manifest-hash"},
            request["ExpressionAttributeValues"][":previous_hash"],
        )


# Change trail: @hungxqt - 2026-07-29 - Added regression coverage for initial and chained checkpoint conditions.
