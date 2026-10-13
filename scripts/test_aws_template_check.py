"""Tests of scripts/aws-template-check.py version, on the repository's template and on
copies of it changed in one place each.

    python3 -m unittest discover -s scripts -p "test_*.py"

The check reads templates with cfn-lint's decoder, so these tests need cfn-lint, as CI's
python3 has it (ci.yml puts cfn-lint's virtual environment first on the PATH); without it
they are skipped, and say so.
"""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "deploy" / "aws" / "apiary.yaml"

spec = importlib.util.spec_from_file_location("aws_template_check", ROOT / "scripts" / "aws-template-check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)

HAS_CFN_LINT = importlib.util.find_spec("cfnlint") is not None

FUNCTION_ENVIRONMENT = """      Environment:
        Variables:
          STACK_ID: !Ref AWS::StackId
      # Each call to the registry"""
VERSION_PROPERTIES = """      ErlangOptions: !Ref ErlangOptions

"""
ROLE_GRANT = """              - !If
                - LooksUpWithDownloadKey
                - Effect: Allow
                  Action: secretsmanager:GetSecretValue
                  Resource: !Ref RegistryCredentials
                - !Ref AWS::NoValue
              - Effect: Allow
                Action: cloudformation:DescribeStacks"""
ROLE_START = """  VersionRole:
    Type: AWS::IAM::Role
    Properties:
"""
FUNCTION_START = "  VersionFunction:\n"
OUTPUTS_START = "Outputs:\n"


def with_resource(text, resource):
    """The template with one more resource, before VersionFunction."""
    return text.replace(FUNCTION_START, resource + "\n" + FUNCTION_START, 1)


@unittest.skipUnless(HAS_CFN_LINT, "cfn-lint is not installed: aws-template-check.py reads templates with it")
class VersionCheck(unittest.TestCase):
    def setUp(self):
        self.source = TEMPLATE.read_text(encoding="utf-8")
        for anchor in (FUNCTION_ENVIRONMENT, VERSION_PROPERTIES, ROLE_GRANT, ROLE_START, FUNCTION_START, OUTPUTS_START):
            self.assertEqual(self.source.count(anchor), 1, anchor)

    def failures(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "apiary.yaml"
            path.write_text(text, encoding="utf-8")
            with contextlib.redirect_stderr(io.StringIO()):
                return check.check_version([path])

    def assert_refused(self, text, reason):
        failures = self.failures(text)
        self.assertTrue(any(reason in failure for failure in failures), failures)

    def test_the_repository_template_passes(self):
        self.assertEqual(self.failures(self.source), [])

    def test_a_dynamic_reference_in_the_function_environment_is_refused(self):
        text = self.source.replace(
            FUNCTION_ENVIRONMENT,
            FUNCTION_ENVIRONMENT.replace(
                "          STACK_ID: !Ref AWS::StackId\n",
                '          STACK_ID: !Ref AWS::StackId\n          KEY: "{{resolve:secretsmanager:example/download-key}}"\n',
            ),
        )
        self.assert_refused(text, "VersionFunction holds a dynamic reference")

    def test_a_dynamic_reference_in_the_resource_properties_is_refused(self):
        text = self.source.replace(
            VERSION_PROPERTIES,
            '      ErlangOptions: !Ref ErlangOptions\n      Key: !Sub "{{resolve:secretsmanager:${RegistryCredentials}}}"\n\n',
        )
        self.assert_refused(text, "Version holds a dynamic reference")

    def test_the_secret_named_anywhere_else_is_refused(self):
        for text, where in (
            (
                self.source.replace(
                    FUNCTION_ENVIRONMENT,
                    FUNCTION_ENVIRONMENT.replace(
                        "          STACK_ID: !Ref AWS::StackId\n",
                        "          STACK_ID: !Ref AWS::StackId\n          SECRET: !Ref RegistryCredentials\n",
                    ),
                ),
                "Resources.VersionFunction.Properties.Environment.Variables.SECRET",
            ),
            (
                self.source.replace(
                    VERSION_PROPERTIES,
                    '      ErlangOptions: !Ref ErlangOptions\n      Other: !Sub "${RegistryCredentials}"\n\n',
                ),
                "Resources.Version.Properties.Other.Fn::Sub",
            ),
            (
                self.source.replace(
                    OUTPUTS_START,
                    "Outputs:\n  DownloadKeySecret:\n    Condition: HasDownloadKey\n    Value: !Ref RegistryCredentials\n",
                ),
                "Outputs.DownloadKeySecret.Value",
            ),
        ):
            with self.subTest(where=where):
                self.assert_refused(text, f"{where} names RegistryCredentials")

    def test_a_policy_attached_to_the_role_is_refused(self):
        statement = (
            "      PolicyDocument:\n"
            '        Version: "2012-10-17"\n'
            "        Statement:\n"
            "          - Effect: Allow\n"
            "            Action: secretsmanager:GetSecretValue\n"
            '            Resource: "*"\n'
        )
        for kind, attach in (
            ("AWS::IAM::Policy", "      PolicyName: more\n      Roles: [!Ref VersionRole]\n"),
            ("AWS::IAM::ManagedPolicy", "      Roles: [!Ref VersionRole]\n"),
            ("AWS::IAM::RolePolicy", "      PolicyName: more\n      RoleName: !Ref VersionRole\n"),
        ):
            with self.subTest(kind=kind):
                text = with_resource(self.source, f"  More:\n    Type: {kind}\n    Properties:\n{attach}{statement}")
                self.assert_refused(text, f"More, an {kind}, attaches more to VersionRole")

    def test_a_policy_attached_by_the_role_name_is_refused(self):
        text = self.source.replace(ROLE_START, ROLE_START + "      RoleName: example-version\n")
        text = with_resource(
            text,
            "  More:\n    Type: AWS::IAM::Policy\n    Properties:\n      PolicyName: more\n"
            "      Roles: [example-version]\n      PolicyDocument:\n"
            '        Version: "2012-10-17"\n        Statement:\n          - Effect: Allow\n'
            '            Action: secretsmanager:GetSecretValue\n            Resource: "*"\n',
        )
        self.assert_refused(text, "More, an AWS::IAM::Policy, attaches more to VersionRole")

    def test_the_grant_for_any_download_key_is_refused(self):
        text = self.source.replace(ROLE_GRANT, ROLE_GRANT.replace("LooksUpWithDownloadKey", "HasDownloadKey"))
        self.assert_refused(text, "VersionRole allows other than reading RegistryCredentials for Qory Apiary Pro")

    def test_another_action_is_refused(self):
        text = self.source.replace(
            ROLE_GRANT, ROLE_GRANT.replace("Action: cloudformation:DescribeStacks", "Action: [cloudformation:DescribeStacks, cloudformation:UpdateStack]")
        )
        self.assert_refused(text, "VersionRole allows other than")

    def test_a_parameter_that_is_not_a_property_is_refused(self):
        for parameter in ("Features", "ErlangOptions"):
            with self.subTest(parameter=parameter):
                line = f"      {parameter}: !Ref {parameter}\n"
                self.assertEqual(self.source.count(line), 1, line)
                text = self.source.replace(line, "")
                self.assert_refused(text, f"Version is not given {parameter} as a property")

    def test_the_key_as_a_property_is_refused(self):
        text = self.source.replace(VERSION_PROPERTIES, '      ErlangOptions: !Ref ErlangOptions\n      Key: !Ref ProDownloadKey\n\n')
        self.assert_refused(text, "Version is given ProDownloadKey")

    def test_an_image_not_from_the_resource_is_refused(self):
        text = self.source.replace("            - !GetAtt Version.Image\n          Essential", '            - !Sub "${Version.Image}"\n          Essential')
        self.assertNotEqual(text, self.source)
        self.assert_refused(text, "the task's image is not Version's Image")


if __name__ == "__main__":
    unittest.main()
