"""Check deploy/aws/apiary.yaml against its stack policy, and against a release's template.

    python scripts/aws-template-check.py policy
    python scripts/aws-template-check.py secrets previous-apiary.yaml

policy: every resource stack-policy.json names exists in the template; the database and the
four key secrets are each denied Update:Replace and Update:Delete; and the ProtectCommand
output sets the same policy as the file. A renamed resource would otherwise lose its guard
without a word.

secrets: the five secrets are the same in the template as in the one given (the previous
release's): their type, condition, deletion and replacement policies and properties. A
changed property can replace a secret, and a replaced secret is generated anew.

Needs cfn-lint installed (its template decoder reads CloudFormation's short forms, such as
!Ref, as their long forms).
"""

import json
import re
import sys
from pathlib import Path

from cfnlint.decode import decode

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "deploy" / "aws" / "apiary.yaml"
POLICY = ROOT / "deploy" / "aws" / "stack-policy.json"

GUARDED = ["Database", "SecretKeyBase", "EncryptionSecret", "SigningSecret", "DatabasePassword"]
SECRETS = ["SecretKeyBase", "EncryptionSecret", "SigningSecret", "DatabasePassword", "SmtpPasswordSecret"]


def load(path):
    template, matches = decode(str(path))
    if matches or template is None:
        for match in matches:
            print(f"{path}: {match}", file=sys.stderr)
        sys.exit(f"{path} is not a template cfn-lint can read")
    # The decoder's own mapping and string types, as plain JSON values.
    return json.loads(json.dumps(template))


def as_list(value):
    return value if isinstance(value, list) else [value]


def check_policy():
    template = load(TEMPLATE)
    policy = json.loads(POLICY.read_text())
    resources = template.get("Resources", {})
    failures = []

    named = set()
    denied = {}
    for statement in policy["Statement"]:
        for resource in as_list(statement["Resource"]):
            if resource == "*":
                continue
            logical_id = resource.removeprefix("LogicalResourceId/")
            if logical_id == resource:
                failures.append(f"stack-policy.json names {resource}, not a LogicalResourceId/")
                continue
            named.add(logical_id)
            if statement["Effect"] == "Deny":
                denied.setdefault(logical_id, set()).update(as_list(statement["Action"]))

    for logical_id in sorted(named - resources.keys()):
        failures.append(f"stack-policy.json names {logical_id}, which apiary.yaml has no resource for")

    for logical_id in GUARDED:
        missing = {"Update:Replace", "Update:Delete"} - denied.get(logical_id, set())
        if missing:
            failures.append(f"stack-policy.json does not deny {', '.join(sorted(missing))} on {logical_id}")

    command = template.get("Outputs", {}).get("ProtectCommand", {}).get("Value", {})
    command = command.get("Fn::Sub") if isinstance(command, dict) else None
    body = re.search(r"--stack-policy-body '([^']*)'", command or "")
    if not body:
        failures.append("the ProtectCommand output sets no --stack-policy-body")
    elif json.loads(body.group(1)) != policy:
        failures.append("the ProtectCommand output sets another policy than stack-policy.json")

    return failures


def check_secrets(previous_path):
    current = load(TEMPLATE).get("Resources", {})
    previous = load(previous_path).get("Resources", {})
    failures = []
    for logical_id in SECRETS:
        if logical_id not in previous:
            failures.append(f"{previous_path} has no {logical_id} to compare with")
        elif current.get(logical_id) != previous[logical_id]:
            failures.append(
                f"{logical_id} differs from {previous_path}:\n"
                f"  before: {json.dumps(previous[logical_id], sort_keys=True)}\n"
                f"  after:  {json.dumps(current.get(logical_id), sort_keys=True)}"
            )
    return failures


def main(argv):
    if argv[1:] == ["policy"]:
        failures = check_policy()
    elif len(argv) == 3 and argv[1] == "secrets":
        failures = check_secrets(argv[2])
    else:
        sys.exit(__doc__)

    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main(sys.argv)
