"""Tests of scripts/aws-template-release.py, on the repository's template and on small ones.

    python3 -m unittest discover -s scripts -p "test_*.py"

The standard library alone: no YAML reader, so the copies are checked as text here, and as
templates by scripts/aws-template-check.py copies in CI.
"""

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "aws-template-release.py"
TEMPLATE = ROOT / "deploy" / "aws" / "apiary.yaml"

spec = importlib.util.spec_from_file_location("aws_template_release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

COMMUNITY_FIRST = release.texts(release.COMMUNITY, "1.2.3", "")
PRO_FIRST = release.texts(release.PRO, "1.2.3", "1.2.4")

# The test parts of the repository's template, as text: each is in the test copy and not in
# a release's.
TEST_TEXTS = [
    "For testing only",
    "TestImage: { default: Test image (leave empty) }",
    "  TestImage:\n    Type: String",
    "replaces the image the Edition and Version pick",
    "TestImageNeedsDownloadKey:",
    '      - !Equals [!Ref TestImage, ""]',
    'HasTestImage: !Not [!Equals [!Ref TestImage, ""]]',
    "Image: !If\n            - HasTestImage\n            - !Ref TestImage",
    '      - HasTestImage\n      - !Sub "Test image ${TestImage}"',
    "# With Test image, exactly the image it names.",
    "# With Test image, the image the stack runs in place of a version.",
]

# A small template in the repository's shape: a marked block, a marked line and an !If.
SMALL = """\
# A template.
# [test copy]
# The test parts.
# [/test copy]
Parameters:
  Edition:
    Type: String
  # [test copy]
  TestImage:
    Type: String
  # [/test copy]
Conditions:
  IsPro: !Equals [!Ref Edition, Qory Apiary Pro]
  HasTestImage: !Not [!Equals [!Ref TestImage, ""]]  # [test copy]
Resources:
  Task:
    Properties:
      Image: !If
        - HasTestImage
        - !Ref TestImage
        - !Sub
          - ${Repository}:latest
          - Repository: example
      Attestation: none
"""


def copy(text, kind, targets=()):
    """The copy's text, or the failures that refuse it."""
    written, failures = release.write_copy(text, kind, list(targets))
    return written if written is not None else failures


class RepositoryTemplate(unittest.TestCase):
    def setUp(self):
        self.source = TEMPLATE.read_text(encoding="utf-8")

    def test_the_source_marks_every_test_part(self):
        for text in TEST_TEXTS:
            self.assertIn(text, self.source)
        self.assertNotIn("Also needed to pull a test image.", self.source)
        self.assertNotIn("Ignored when a test image is set.", self.source)

    def test_a_release_copy_has_no_test_part_or_wording(self):
        for targets in (COMMUNITY_FIRST, PRO_FIRST):
            written = copy(self.source, release.RELEASE, targets)
            self.assertIsInstance(written, str, written)
            self.assertEqual(release.release_copy_failures(written), [])
            for text in TEST_TEXTS:
                self.assertNotIn(text, written)
            self.assertNotIn("TestImage", written)
            self.assertNotIn("[test copy]", written)
            self.assertIn(f'Description: "{release.VERSION_HELP}"', written)
            self.assertIn("          Image: !Sub\n            - ${Repository}:${Tag}\n", written)
            self.assertIn("    Value: !If\n      - HasVersionOverride\n      - !Ref VersionOverride\n", written)

    def test_a_test_copy_has_every_test_part(self):
        for targets in (COMMUNITY_FIRST, PRO_FIRST):
            written = copy(self.source, release.TEST, targets)
            self.assertIsInstance(written, str, written)
            for text in TEST_TEXTS:
                self.assertIn(text, written)
            self.assertNotIn("[test copy]", written)
            self.assertIn(f'Description: "{release.VERSION_HELP}"', written)

    def test_a_test_copy_leaves_out_the_markers_alone(self):
        written = copy(self.source, release.TEST)
        expected = [
            line.removesuffix(release.MARKED)
            for line in self.source.split("\n")
            if line.strip() not in (release.OPEN, release.CLOSE)
        ]
        self.assertEqual(written.split("\n"), expected)

    def test_a_copy_already_written_is_refused(self):
        for kind in (release.RELEASE, release.TEST):
            written = copy(self.source, kind, COMMUNITY_FIRST)
            for again in (release.RELEASE, release.TEST):
                failures = copy(written, again, COMMUNITY_FIRST)
                self.assertIsInstance(failures, list)
                self.assertIn("no marked parts", failures[0])


class Copies(unittest.TestCase):
    def test_the_release_copy_of_a_small_template(self):
        self.assertEqual(
            copy(SMALL, release.RELEASE),
            """\
# A template.
Parameters:
  Edition:
    Type: String
Conditions:
  IsPro: !Equals [!Ref Edition, Qory Apiary Pro]
Resources:
  Task:
    Properties:
      Image: !Sub
        - ${Repository}:latest
        - Repository: example
      Attestation: none
""",
        )

    def test_the_test_copy_of_a_small_template(self):
        written = copy(SMALL, release.TEST)
        self.assertNotIn("[test copy]", written)
        self.assertIn('  HasTestImage: !Not [!Equals [!Ref TestImage, ""]]\n', written)
        self.assertIn("  TestImage:\n    Type: String\nConditions:", written)
        self.assertIn("      Image: !If\n        - HasTestImage\n", written)

    def test_no_marked_parts_is_refused(self):
        failures = copy("Parameters:\n  Edition:\n    Type: String\n", release.TEST)
        self.assertIn("no marked parts", failures[0])

    def test_an_unbalanced_marker_is_refused(self):
        for text, reason in (
            ("# [test copy]\n# a test\n", "never closed"),
            ("# [/test copy]\n# [test copy]\n# a\n# [/test copy]\n", "closes no block"),
            ("# [test copy]\n# [test copy]\n# a\n# [/test copy]\n", "inside the block"),
            ("# [test copy]\n# [/test copy]\n", "is empty"),
            ("# [test copy]\nKey: value  # [test copy]\n# [/test copy]\n", "inside the block"),
            ("Key: value # [test copy] more\n", "neither alone on its line"),
        ):
            for kind in (release.RELEASE, release.TEST):
                with self.subTest(text=text, kind=kind):
                    failures = copy(text, kind)
                    self.assertIsInstance(failures, list)
                    self.assertIn(reason, failures[0])

    def test_unmarked_test_wording_is_refused(self):
        text = SMALL.replace("# A template.", "# A template, tested before a release.")
        failures = copy(text, release.RELEASE)
        self.assertIsInstance(failures, list)
        self.assertIn("line 1 holds test wording (tested)", failures[0])
        self.assertIsInstance(copy(text, release.TEST), str)

    def test_a_then_branch_over_two_lines_is_refused(self):
        text = SMALL.replace(
            "        - !Ref TestImage\n", "        - !Join\n          - ''\n          - [!Ref TestImage]\n"
        )
        failures = copy(text, release.RELEASE)
        self.assertIsInstance(failures, list)
        self.assertEqual(
            failures[0], "line 20: the !If on line 18 has its value for a test image over more than one line"
        )

    def test_an_if_without_a_value_without_a_test_image_is_refused(self):
        text = SMALL.replace(
            "        - !Sub\n          - ${Repository}:latest\n          - Repository: example\n", ""
        )
        failures = copy(text, release.RELEASE)
        self.assertIsInstance(failures, list)
        self.assertEqual(failures[0], "line 21: the !If on line 18 has no value without a test image")

    def test_an_if_in_another_shape_is_refused(self):
        text = SMALL.replace(
            "      Image: !If\n        - HasTestImage\n        - !Ref TestImage\n        - !Sub\n"
            "          - ${Repository}:latest\n          - Repository: example\n",
            "      Image: !If [HasTestImage, !Ref TestImage, example]\n",
        )
        failures = copy(text, release.RELEASE)
        self.assertIsInstance(failures, list)
        self.assertIn("names the test image", failures[0])

    def test_a_resource_on_the_test_image_condition_is_refused(self):
        text = SMALL.replace("  Task:\n", "  Task:\n    Condition: HasTestImage\n")
        failures = copy(text, release.RELEASE)
        self.assertIsInstance(failures, list)
        self.assertEqual(len(failures), 1)
        self.assertIn("Condition: HasTestImage", failures[0])


class Wording(unittest.TestCase):
    def test_words_that_pass(self):
        for word in ("latest", "attestation", "Latest", "contest", "testimony", "release"):
            with self.subTest(word=word):
                self.assertEqual(release.release_copy_failures(f"# the {word} one"), [])

    def test_words_that_are_refused(self):
        for word in ("test", "Tests", "testing", "tested", "pre-release", "prerelease", "Pre-releases"):
            with self.subTest(word=word):
                self.assertEqual(len(release.release_copy_failures(f"# the {word} one")), 1)

    def test_markers_and_the_test_image_are_refused(self):
        self.assertIn("marker", release.release_copy_failures("# [/test copy]")[0])
        self.assertIn("names the test image", release.release_copy_failures("Key: !Ref TestImage")[0])


class CommandLine(unittest.TestCase):
    def run_script(self, path, *arguments):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(path), *arguments,
             "--edition-default", release.COMMUNITY, "--community-version", "1.2.3", "--pro-version", ""],
            capture_output=True,
            text=True,
        )

    def test_release_is_the_default_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "apiary.yaml"
            path.write_text(TEMPLATE.read_text(encoding="utf-8"), encoding="utf-8")
            result = self.run_script(path)
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = copy(TEMPLATE.read_text(encoding="utf-8"), release.RELEASE, COMMUNITY_FIRST)
            self.assertEqual(path.read_text(encoding="utf-8"), expected)

    def test_a_refused_copy_writes_nothing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "apiary.yaml"
            text = TEMPLATE.read_text(encoding="utf-8").replace("# Qory Apiary on AWS", "# Qory Apiary on AWS, tested")
            path.write_text(text, encoding="utf-8")
            result = self.run_script(path, "--copy", "release")
            self.assertEqual(result.returncode, 1)
            self.assertIn("test wording", result.stderr)
            self.assertEqual(path.read_text(encoding="utf-8"), text)


if __name__ == "__main__":
    unittest.main()
