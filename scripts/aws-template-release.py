"""Write a release's versions into a copy of the AWS template, deploy/aws/apiary.yaml.

    python3 scripts/aws-template-release.py TEMPLATE [--copy release|test] \\
        --edition-default EDITION --community-version X.Y.Z --pro-version [X.Y.Z]

TEMPLATE is written in place, and must be the repository's template, whose Release mapping
is empty. EDITION, the edition the form offers first, is "Qory Apiary Community" or
"Qory Apiary Pro". --pro-version may be empty, unless EDITION is Qory Apiary Pro: the copy
then installs Qory Apiary Pro only with a version typed under Version, and a Rule says so.

--copy says which copy is written. The repository's template holds the test parts, each a
block of lines between a "# [test copy]" line and a "# [/test copy]" line, or a line ending
in "  # [test copy]", and each "KEY: !If" whose first item is HasTestImage: the form's Test
image field, its group, its rule and its comments.

- release, the default: the copy a release attaches. The marked parts are left out, and each
  "KEY: !If" on HasTestImage becomes its third item, the value without a test image; any
  other use of HasTestImage is refused. The copy must then hold no marker, no TestImage or
  HasTestImage and no test wording (TEST_WORDING), comments included, or nothing is written.
- test: the copy for a test before a release, never published. Only the marker lines and the
  markers at the ends of lines are left out.

Either way the template must hold marked parts, each block closed and none inside another.

Written in: the Release mapping's CommunityVersion and ProVersion, and the same versions in
the Rules that refuse an edition with no version; Edition's default and help; Version's
(VersionOverride's) label and help, the label naming EDITION and its version when
--pro-version is given; and the Version output's description, naming EDITION and its
version. Each is found by its place in the template, its keys from the top, and must be
there exactly once and be written exactly once, in ASCII alone, or nothing is written.

The template is read as text: the standard library has no YAML reader, and the lines
written keep the rest of the file, its comments included, as it is.

Its tests: python3 -m unittest discover -s scripts -p "test_*.py"
"""

import argparse
import json
import re
import sys
from pathlib import Path

COMMUNITY = "Qory Apiary Community"
PRO = "Qory Apiary Pro"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?")

RELEASE = "release"
TEST = "test"
OPEN = "# [test copy]"
CLOSE = "# [/test copy]"
MARKED = "  " + OPEN
# Words a release's copy never holds, whole and in any case: "latest" and "attestation" pass.
TEST_WORDING = re.compile(r"\b(test(s|ed|ing)?|pre-?releases?)\b", re.IGNORECASE)
TEST_NAMES = re.compile(r"TestImage")
IF_LINE = re.compile(r"^(?P<head> *(?:- )?[^\s#-][^#]*?:) !If$")

EDITION_HELP = "Qory Apiary Community is free and open source. Qory Apiary Pro needs the download key we sent you."
PRO_TEMPLATE_HELP = "For Qory Apiary Pro, use the Qory Apiary Pro template we sent you."
WAY_BACK_HELP = "Moving from Qory Apiary Community to Qory Apiary Pro is possible later; the way back is not."
VERSION_HELP = "Leave empty to install the version this template names."


def texts(edition_default, community_version, pro_version):
    """The values written in, by their place in the template."""
    version = pro_version if edition_default == PRO else community_version
    named = f"{edition_default} {version}"
    edition_help = [EDITION_HELP, WAY_BACK_HELP] + ([] if pro_version else [PRO_TEMPLATE_HELP])
    # The approved labels: of a copy that names no Qory Apiary Pro version, as release.yml writes
    # it, and of a copy that names both.
    label = f"Version (leave empty for {named})" if pro_version else "Version (leave empty for this template's)"

    return [
        # The Release mapping, which the image's tag reads; a repository's template has both empty.
        (("Mappings", "Release", "Versions", "CommunityVersion"), '""', quote(community_version)),
        (("Mappings", "Release", "Versions", "ProVersion"), '""', quote(pro_version)),
        # The same versions, in the Rules that refuse an edition whose version is empty.
        (
            ("Rules", "CommunityVersionNamed", "Assertions", "- Assert"),
            '!Not [!Equals [!Ref VersionOverride, ""]]',
            f"!Not [!Equals [!Ref VersionOverride, {quote(community_version)}]]",
        ),
        (
            ("Rules", "ProVersionNamed", "Assertions", "- Assert"),
            '!Not [!Equals [!Ref VersionOverride, ""]]',
            f"!Not [!Equals [!Ref VersionOverride, {quote(pro_version)}]]",
        ),
        (("Parameters", "Edition", "Default"), None, quote(edition_default)),
        (("Parameters", "Edition", "Description"), None, quote(" ".join(edition_help))),
        (
            ("Parameters", "VersionOverride", "Description"),
            None,
            quote(VERSION_HELP),
        ),
        (
            ("Metadata", "AWS::CloudFormation::Interface", "ParameterLabels", "VersionOverride"),
            None,
            f"{{ default: {quote(label)} }}",
        ),
        (
            ("Outputs", "Version", "Description"),
            None,
            quote(f"The version the stack runs. This template's is {named}."),
        ),
    ]


def quote(value):
    # A JSON string is a YAML double-quoted scalar.
    return json.dumps(value, ensure_ascii=False)


def where(path):
    return ".".join(key.removeprefix("- ") for key in path)


def indentation(line):
    return len(line) - len(line.lstrip(" "))


def ignored(line):
    stripped = line.strip()
    return not stripped or stripped.startswith("#")


def find(lines, path):
    """The index of the one line at path, each key in the block of the one before it."""
    start, end, indent = 0, len(lines), 0
    for depth, key in enumerate(path):
        pattern = re.compile(" " * indent + re.escape(key) + r":(\s|$)")
        hits = [i for i in range(start, end) if pattern.match(lines[i])]
        if len(hits) != 1:
            raise LookupError(f"{where(path[: depth + 1])} is in the template {len(hits)} times, not once")
        found = hits[0]
        start, end = found + 1, found + 1
        while end < len(lines) and (ignored(lines[end]) or indentation(lines[end]) > indent):
            end += 1
        indent += 2
    return found


def write(text, targets):
    lines = text.split("\n")
    failures = []
    for path, placeholder, value in targets:
        try:
            index = find(lines, path)
        except LookupError as error:
            failures.append(str(error))
            continue
        line = lines[index]
        prefix = line[: indentation(line)] + path[-1] + ":"
        current = line[len(prefix) :].strip()
        # The value is written on this one line, so it must hold all of it: a key's value
        # on the lines below would stay behind. A sequence item's key sits two further in.
        key_indent = indentation(line) + (2 if path[-1].startswith("- ") else 0)
        below = next((other for other in lines[index + 1 :] if not ignored(other)), "")
        if not current or indentation(below) > key_indent:
            failures.append(f"{where(path)} has its value on the lines below, not on its own line")
        elif placeholder is not None and current != placeholder:
            failures.append(
                f"{where(path)} is {current}, not {placeholder}: the template is not the repository's"
            )
        else:
            lines[index] = f"{prefix} {value}"

    if failures:
        return None, failures

    # Each place again, now holding its value once, in ASCII alone: the console shows
    # another character as "?" (scripts/aws-template-check.py ascii).
    for path, _placeholder, value in targets:
        line = lines[find(lines, path)]
        if line.count(value) != 1 or not line.endswith(value):
            failures.append(f"{where(path)} was not written")
        elif not value.isascii():
            failures.append(f"{where(path)} would hold a character that is not ASCII: {value}")
    return "\n".join(lines), failures


def marked_parts(lines):
    """The marked parts: (first, last) line indexes of each block, markers included, and the
    index of each line that ends in a marker. Raises ValueError on an unbalanced marker."""
    blocks, ends, opened = [], [], None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == OPEN:
            if opened is not None:
                raise ValueError(f"line {index + 1}: {OPEN} inside the block opened on line {opened + 1}")
            opened = index
        elif stripped == CLOSE:
            if opened is None:
                raise ValueError(f"line {index + 1}: {CLOSE} closes no block")
            if opened == index - 1:
                raise ValueError(f"line {index + 1}: the block opened on line {opened + 1} is empty")
            blocks.append((opened, index))
            opened = None
        elif line.endswith(MARKED) and line[: -len(MARKED)].strip():
            if opened is not None:
                raise ValueError(f"line {index + 1}: a marked line inside the block opened on line {opened + 1}")
            ends.append(index)
        elif "[test copy]" in line or "[/test copy]" in line:
            raise ValueError(f"line {index + 1}: a marker that is neither alone on its line nor at the line's end")
    if opened is not None:
        raise ValueError(f"line {opened + 1}: {OPEN} is never closed")
    if not blocks and not ends:
        raise ValueError("the template has no marked parts: it is not the repository's, or a copy already written")
    return blocks, ends


def unwrap_test_image(lines, numbers):
    """Each KEY: !If whose items are - HasTestImage, the value with a test image on one line,
    and the value without one, becomes KEY: and that last value, its lines two spaces less
    indented. Raises ValueError on any other shape, naming the template's line (numbers, by
    index)."""
    result, index = [], 0

    def at(offset):
        return numbers[min(index + offset, len(numbers) - 1)]

    while index < len(lines):
        line = lines[index]
        match = IF_LINE.match(line)
        after = lines[index + 1] if index + 1 < len(lines) else ""
        if not (match and after.strip() == "- HasTestImage"):
            result.append(line)
            index += 1
            continue
        items = indentation(after)
        if items <= indentation(line):
            raise ValueError(f"line {at(1)}: - HasTestImage is not an item of the !If above it")
        then = lines[index + 2] if index + 2 < len(lines) else ""
        if indentation(then) != items or not then.lstrip().startswith("- "):
            raise ValueError(f"line {at(2)}: the !If on line {at(0)} has no value for a test image after HasTestImage")
        otherwise = lines[index + 3] if index + 3 < len(lines) else ""
        if otherwise.strip() and indentation(otherwise) > items:
            raise ValueError(
                f"line {at(2)}: the !If on line {at(0)} has its value for a test image over more than one line"
            )
        if indentation(otherwise) != items or not otherwise.lstrip().startswith("- "):
            raise ValueError(f"line {at(3)}: the !If on line {at(0)} has no value without a test image")
        end = index + 4
        while end < len(lines) and (not lines[end].strip() or indentation(lines[end]) > items):
            end += 1
        if end < len(lines) and indentation(lines[end]) == items and lines[end].lstrip().startswith("- "):
            raise ValueError(f"line {numbers[end]}: the !If on line {at(0)} has more than three items")
        while end > index + 4 and not lines[end - 1].strip():
            end -= 1
        result.append(f"{match.group('head')} {otherwise.lstrip()[2:]}")
        for rest in lines[index + 4 : end]:
            result.append(rest[2:] if rest.startswith(" " * (items + 2)) else rest)
        index = end
    return result


def release_copy_failures(text):
    """What a release's copy holds that it must not: a marker, TestImage or HasTestImage, or
    test wording, comments included, each by its line."""
    failures = []
    for number, line in enumerate(text.split("\n"), start=1):
        if "[test copy]" in line or "[/test copy]" in line:
            failures.append(f"line {number} holds a test copy marker: {line.strip()}")
        elif TEST_NAMES.search(line):
            failures.append(f"line {number} names the test image: {line.strip()}")
        else:
            words = sorted({match.group(0) for match in TEST_WORDING.finditer(line)})
            if words:
                failures.append(f"line {number} holds test wording ({', '.join(words)}): {line.strip()}")
    return failures


def make_copy(text, copy):
    """The release or the test copy of the repository's template, before its versions are
    written. Raises ValueError when the template cannot make it."""
    lines = text.split("\n")
    blocks, ends = marked_parts(lines)
    in_block = {index for first, last in blocks for index in range(first, last + 1)}
    markers = {index for first, last in blocks for index in (first, last)}
    if copy == TEST:
        kept = [
            line[: -len(MARKED)].rstrip() if index in ends else line
            for index, line in enumerate(lines)
            if index not in markers
        ]
        return "\n".join(kept)
    kept = [index for index in range(len(lines)) if index not in in_block and index not in ends]
    return "\n".join(unwrap_test_image([lines[index] for index in kept], [index + 1 for index in kept]))


def write_copy(text, copy, targets):
    """The copy, its versions written, and what refuses it."""
    try:
        text = make_copy(text, copy)
    except ValueError as error:
        return None, [str(error)]
    text, failures = write(text, targets)
    if not failures and copy == RELEASE:
        failures = release_copy_failures(text)
    return (None, failures) if failures else (text, [])


def main(argv):
    parser = argparse.ArgumentParser(
        description="Write a release's versions into a copy of deploy/aws/apiary.yaml, in place."
    )
    parser.add_argument("template", type=Path)
    parser.add_argument(
        "--copy",
        choices=[RELEASE, TEST],
        default=RELEASE,
        help="release (the default): without the test parts; test: with them, never published",
    )
    parser.add_argument("--edition-default", required=True, choices=[COMMUNITY, PRO])
    parser.add_argument("--community-version", required=True)
    parser.add_argument("--pro-version", required=True, help="may be empty")
    args = parser.parse_args(argv[1:])

    if not VERSION.fullmatch(args.community_version):
        parser.error(f"--community-version {args.community_version!r} is not a version such as 0.2.0")
    if args.pro_version and not VERSION.fullmatch(args.pro_version):
        parser.error(f"--pro-version {args.pro_version!r} is not a version such as 0.2.0, or empty")
    if args.edition_default == PRO and not args.pro_version:
        parser.error(f"--edition-default {PRO!r} needs --pro-version")

    text, failures = write_copy(
        args.template.read_text(encoding="utf-8"),
        args.copy,
        texts(args.edition_default, args.community_version, args.pro_version),
    )
    if failures:
        for failure in failures:
            print(f"{args.template}: {failure}", file=sys.stderr)
        sys.exit(1)
    args.template.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv)
