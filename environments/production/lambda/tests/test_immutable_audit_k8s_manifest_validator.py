import importlib.util
import sys
import types
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


MODULE_PATH = (
    Path(__file__).resolve().parents[1]
    / "immutable_audit_k8s_manifest_validator.py"
)


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
        "immutable_audit_k8s_manifest_validator_under_test", MODULE_PATH
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


def _candidate(key, manifest_hash, previous_hash, minute):
    start = datetime(2026, 7, 29, 0, minute, tzinfo=timezone.utc)
    return {
        "key": key,
        "last_modified": start,
        "window_start": start,
        "window_end": start.replace(minute=minute + 1),
        "manifest": {
            "manifest_hash": manifest_hash,
            "previous_manifest_hash": previous_hash,
        },
    }


class SelectManifestChainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = _load_module()

    def test_bounded_lookback_starts_from_external_predecessor(self):
        candidates = [
            _candidate("manifest-1", "hash-1", "hash-before-lookback", 0),
            _candidate("manifest-2", "hash-2", "hash-1", 1),
            _candidate("manifest-3", "hash-3", "hash-2", 2),
        ]

        selected = self.module._select_manifest_chain(candidates)

        self.assertEqual(
            ["manifest-1", "manifest-2", "manifest-3"],
            [item["key"] for item in selected],
        )

    def test_explicit_predecessor_is_still_enforced(self):
        candidates = [
            _candidate("expected", "hash-1", "expected-predecessor", 0),
            _candidate("unrelated", "other-1", "other-predecessor", 1),
        ]

        selected = self.module._select_manifest_chain(
            candidates,
            expected_initial_previous_hash="expected-predecessor",
        )

        self.assertEqual(["expected"], [item["key"] for item in selected])

    def test_cycle_without_boundary_is_rejected(self):
        candidates = [
            _candidate("manifest-1", "hash-1", "hash-2", 0),
            _candidate("manifest-2", "hash-2", "hash-1", 1),
        ]

        selected = self.module._select_manifest_chain(candidates)

        self.assertEqual([], selected)


# Change trail: @minh-khoa - 2026-07-29 - Cover bounded-lookback chain selection.
