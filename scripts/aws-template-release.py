"""Write a release's versions into a copy of the AWS template, deploy/aws/apiary.yaml.

    python3 scripts/aws-template-release.py TEMPLATE --edition-default EDITION \\
        --community-version X.Y.Z --pro-version [X.Y.Z]

TEMPLATE is written in place, and must be the repository's template, whose Release mapping
is empty. EDITION, the edition the form offers first, is "Apiary Community" or "Apiary Pro".
--pro-version may be empty, unless EDITION is Apiary Pro: the copy then installs Apiary Pro
only with a version typed under Version, and a Rule says so.

Written in: the Release mapping's CommunityVersion and ProVersion, and the same versions in
the Rules that refuse an edition with no version; Edition's default and help; Version's
(VersionOverride's) label and help, the help naming EDITION and its version, and the label
too when --pro-version is given; and the Version output's description. Each is found by its place in the template, its keys from the top,
and must be there exactly once and be written exactly once, or nothing is written.

The template is read as text: the standard library has no YAML reader, and the lines
written keep the rest of the file, its comments included, as it is.
"""

import argparse
import json
import re
import sys
from pathlib import Path

COMMUNITY = "Apiary Community"
PRO = "Apiary Pro"
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?")

EDITION_HELP = "Apiary Community is free and open source. Apiary Pro needs the download key we sent you."
PRO_TEMPLATE_HELP = "For Apiary Pro, use the Apiary Pro template we sent you."
WAY_BACK_HELP = "Apiary Community → Apiary Pro is possible later; the way back is not."


def texts(edition_default, community_version, pro_version):
    """The values written in, by their place in the template."""
    version = pro_version if edition_default == PRO else community_version
    named = f"{edition_default} {version}"
    edition_help = [EDITION_HELP] + ([] if pro_version else [PRO_TEMPLATE_HELP]) + [WAY_BACK_HELP]
    # The approved labels: of a copy that names no Apiary Pro version, as release.yml writes
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
            quote(
                f"Empty installs or upgrades to {named}, the version of this template. "
                "Only to run another version on purpose: type it here. "
                "Ignored when a test image is set."
            ),
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

    # Each place again, now holding its value once.
    for path, _placeholder, value in targets:
        line = lines[find(lines, path)]
        if line.count(value) != 1 or not line.endswith(value):
            failures.append(f"{where(path)} was not written")
    return "\n".join(lines), failures


def main(argv):
    parser = argparse.ArgumentParser(
        description="Write a release's versions into a copy of deploy/aws/apiary.yaml, in place."
    )
    parser.add_argument("template", type=Path)
    parser.add_argument("--edition-default", required=True, choices=[COMMUNITY, PRO])
    parser.add_argument("--community-version", required=True)
    parser.add_argument("--pro-version", required=True, help="may be empty")
    args = parser.parse_args(argv[1:])

    if not VERSION.fullmatch(args.community_version):
        parser.error(f"--community-version {args.community_version!r} is not a version such as 0.2.0")
    if args.pro_version and not VERSION.fullmatch(args.pro_version):
        parser.error(f"--pro-version {args.pro_version!r} is not a version such as 0.2.0, or empty")
    if args.edition_default == PRO and not args.pro_version:
        parser.error("--edition-default 'Apiary Pro' needs --pro-version")

    text, failures = write(
        args.template.read_text(encoding="utf-8"),
        texts(args.edition_default, args.community_version, args.pro_version),
    )
    if failures:
        for failure in failures:
            print(f"{args.template}: {failure}", file=sys.stderr)
        sys.exit(1)
    args.template.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv)
