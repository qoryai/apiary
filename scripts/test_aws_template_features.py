"""Tests of the AWS template's Features parameter: its AllowedPattern, read from
deploy/aws/apiary.yaml, accepts the values QORY_FEATURES takes and refuses others.

    python3 -m unittest discover -s scripts -p "test_*.py"

The template is read with cfn-lint's decoder, through scripts/aws-template-check.py, so these
tests need cfn-lint, as CI's python3 has it; without it they are skipped, and say so.
CloudFormation matches an AllowedPattern against the whole value, as re.fullmatch does.
"""

import importlib.util
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "deploy" / "aws" / "apiary.yaml"

spec = importlib.util.spec_from_file_location("aws_template_check", ROOT / "scripts" / "aws-template-check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

HAS_CFN_LINT = importlib.util.find_spec("cfnlint") is not None

ACCEPTED = ["", "all", "all-security", "all-observability,security", "observability", "observability,security"]
REFUSED = ["all-", "a, b", "Observability", "a,", "-x", "observability;rm"]


@unittest.skipUnless(HAS_CFN_LINT, "cfn-lint is not installed: the template is read with it")
class FeaturesPattern(unittest.TestCase):
    def setUp(self):
        self.pattern = re.compile(check.load(TEMPLATE)["Parameters"]["Features"]["AllowedPattern"])

    def test_the_values_are_accepted(self):
        for value in ACCEPTED:
            with self.subTest(value=value):
                self.assertIsNotNone(self.pattern.fullmatch(value))

    def test_the_other_values_are_refused(self):
        for value in REFUSED:
            with self.subTest(value=value):
                self.assertIsNone(self.pattern.fullmatch(value))


if __name__ == "__main__":
    unittest.main()
