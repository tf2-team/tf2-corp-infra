import os
import sys
import unittest
from unittest.mock import MagicMock

# Mock boto3 before importing the Lambda module so top-level boto3 client instantiations do not fail
sys.modules["boto3"] = MagicMock()

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from immutable_audit_health_check import validate_cloudtrail_selectors



class TestCloudTrailSelectorContract(unittest.TestCase):
    def setUp(self):
        self.expected_s3_arns = [
            "arn:aws:s3:::techx-prod-tf2-ai-models-493499579600/",
            "arn:aws:s3:::techx-tf-state-493499579600-us-east-1/",
            "arn:aws:s3:::techx-prod-tf2-cloudtrail-immutable-493499579600/",
            "arn:aws:s3:::techx-prod-tf2-k8s-audit-raw-493499579600/",
            "arn:aws:s3:::techx-prod-tf2-athena-results-493499579600-ap-southeast-1/",
            "arn:aws:s3:::company-cdo-493499579600-telemetry/",
        ]

        self.valid_advanced_selectors = [
            {
                "Name": "ManagementWrites",
                "FieldSelectors": [
                    {"Field": "eventCategory", "Equals": ["Management"]},
                    {"Field": "readOnly", "Equals": ["false"]},
                ],
            },
            {
                "Name": "RequiredSecretReads",
                "FieldSelectors": [
                    {"Field": "eventCategory", "Equals": ["Management"]},
                    {"Field": "eventSource", "Equals": ["secretsmanager.amazonaws.com"]},
                    {"Field": "eventName", "Equals": ["GetSecretValue"]},
                ],
            },
            {
                "Name": "SensitiveS3Data",
                "FieldSelectors": [
                    {"Field": "eventCategory", "Equals": ["Data"]},
                    {"Field": "resources.type", "Equals": ["AWS::S3::Object"]},
                    {"Field": "resources.ARN", "StartsWith": self.expected_s3_arns},
                ],
            },
        ]

    def test_valid_selectors_pass(self):
        errors = validate_cloudtrail_selectors([], self.valid_advanced_selectors, self.expected_s3_arns)
        self.assertEqual(errors, [])

    def test_legacy_all_management_read_rejected(self):
        # Basic selector with IncludeManagementEvents=True and ReadWriteType=All
        legacy_basic = [{"IncludeManagementEvents": True, "ReadWriteType": "All"}]
        errors = validate_cloudtrail_selectors(legacy_basic, self.valid_advanced_selectors, self.expected_s3_arns)
        self.assertTrue(any("All-management-read" in e for e in errors))

        # Advanced selector capturing all management events (no readOnly=false or eventName restriction)
        unconstrained_mgmt = [
            {
                "Name": "AllMgmt",
                "FieldSelectors": [{"Field": "eventCategory", "Equals": ["Management"]}],
            }
        ]
        errors = validate_cloudtrail_selectors([], unconstrained_mgmt + self.valid_advanced_selectors[2:], self.expected_s3_arns)
        self.assertTrue(any("All-management-read" in e for e in errors))

    def test_missing_management_writes_fails(self):
        # Remove ManagementWrites selector
        selectors = self.valid_advanced_selectors[1:]
        errors = validate_cloudtrail_selectors([], selectors, self.expected_s3_arns)
        self.assertTrue(any("ManagementWrites" in e for e in errors))

    def test_missing_secret_reads_fails(self):
        # Remove RequiredSecretReads selector
        selectors = [self.valid_advanced_selectors[0], self.valid_advanced_selectors[2]]
        errors = validate_cloudtrail_selectors([], selectors, self.expected_s3_arns)
        self.assertTrue(any("RequiredSecretReads" in e for e in errors))

    def test_missing_s3_prefix_fails(self):
        # Omit one S3 prefix
        incomplete_arns = self.expected_s3_arns[:-1]
        selectors = [
            self.valid_advanced_selectors[0],
            self.valid_advanced_selectors[1],
            {
                "Name": "SensitiveS3Data",
                "FieldSelectors": [
                    {"Field": "eventCategory", "Equals": ["Data"]},
                    {"Field": "resources.type", "Equals": ["AWS::S3::Object"]},
                    {"Field": "resources.ARN", "StartsWith": incomplete_arns},
                ],
            },
        ]
        errors = validate_cloudtrail_selectors([], selectors, self.expected_s3_arns)
        self.assertTrue(any("missing S3 data event ARNs" in e for e in errors))


if __name__ == "__main__":
    unittest.main()

# Change trail: @hungxqt - 2026-07-28 - Unit tests for CloudTrail selector cost contract validation.
