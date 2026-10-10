"""Check deploy/aws/apiary.yaml against its stack policy, and against a release's template.

    python scripts/aws-template-check.py policy
    python scripts/aws-template-check.py outputs
    python scripts/aws-template-check.py kept
    python scripts/aws-template-check.py mappings
    python scripts/aws-template-check.py editions [FILE ...]
    python scripts/aws-template-check.py ascii [FILE ...]
    python scripts/aws-template-check.py secrets previous-apiary.yaml

policy: every resource stack-policy.json names exists in the template; the database and the
four key secrets are each denied Update:Replace and Update:Delete; and the policy the stack
sets on itself at creation is the same as the file's. That policy is the STACK_POLICY of the
function behind the template's one Custom::StackPolicy, whose STACK_ID is the stack's own
id; the function reads neither from the request, which passes it nothing but its
ServiceToken and ServiceTimeout. A renamed resource would otherwise lose its guard without
a word.

outputs: no output's value is a command (none starts with "aws "), in any branch of its
Fn::If: the person installs from the console alone.

kept: the four secrets are kept, on delete (RetainExceptOnCreate) and on replacement
(Retain), each under a name that uses the whole UUID of the stack's ID, not the stack's name
alone, so the secrets a deleted stack kept do not block a new stack of the same name, whose
stack ID is its own; while the download key's
secret, RegistryCredentials, is kept by neither, named in no stack policy and not among the
KeysSecrets output's: it is deleted with the stack. And every log group is kept, on delete
and on replacement (Retain), so a create that rolls back leaves its log to read, keeps a
retention, so its events still go, and uses the stack ID's UUID in its name too. A name
uses it when it is a Fn::Sub whose text names a variable that is exactly
!Select [2, !Split ["/", !Ref AWS::StackId]]: a variable given but not used does not count.

mappings: the Release mapping holds exactly CommunityVersion and ProVersion, the names
scripts/aws-template-release.py writes and Qory Apiary Pro's release relies on, and the Images
mapping exactly Community and Pro; and every Fn::FindInMap names a value the mappings hold.
cfn-lint does not check a Fn::FindInMap inside a Fn::If, where the template's are.

editions: in the template, or in each FILE given (such as a release's copy of the
template), every value compared with !Ref Edition, in a Rule, a Condition or anywhere else,
however deep in a Fn::And, Fn::Or or Fn::Not, is one of Edition's AllowedValues, and each
AllowedValue is compared at least once. A Fn::Equals against a value Edition no longer
allows is never true, so the Rule or Condition it decides stops applying, and cfn-lint
does not say so.

ascii: the template and stack-policy.json, or each FILE given (such as a release's copy of
the template), hold ASCII characters alone, in every description, label, rule text,
output, comment and the functions' code: the AWS console shows another character as "?".
Each other character is named with its line and column.

secrets: the four secrets are the same in the template as in the one given (the previous
release's): their type, condition, deletion and replacement policies and properties. A
changed property can replace a secret, and a replaced secret is generated anew.

Needs cfn-lint installed (its template decoder reads CloudFormation's short forms, such as
!Ref, as their long forms).
"""

import itertools
import json
import re
import sys
import unicodedata
from pathlib import Path

from cfnlint.decode import decode

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "deploy" / "aws" / "apiary.yaml"
POLICY = ROOT / "deploy" / "aws" / "stack-policy.json"

GUARDED = ["Database", "SecretKeyBase", "EncryptionSecret", "SigningSecret", "DatabasePassword"]
SECRETS = ["SecretKeyBase", "EncryptionSecret", "SigningSecret", "DatabasePassword"]
DOWNLOAD_KEY = "RegistryCredentials"
RETAINED = {"Retain", "RetainExceptOnCreate"}
MAPPINGS = {
    "Release": {"Versions": {"CommunityVersion", "ProVersion"}},
    "Images": {"Community": {"Repository"}, "Pro": {"Repository"}},
}
COMMAND = re.compile(r"\s*aws\s")


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


def named(policy):
    """The logical IDs a stack policy names, the actions it denies on each, and what it
    names that is not a logical ID."""
    names, denied, failures = set(), {}, []
    for statement in policy.get("Statement", []):
        for resource in as_list(statement["Resource"]):
            if resource == "*":
                continue
            logical_id = resource.removeprefix("LogicalResourceId/")
            if logical_id == resource:
                failures.append(f"stack-policy.json names {resource}, not a LogicalResourceId/")
                continue
            names.add(logical_id)
            if statement["Effect"] == "Deny":
                denied.setdefault(logical_id, set()).update(as_list(statement["Action"]))
    return names, denied, failures


def stack_policy_body(template):
    """The policy the stack sets on itself, and what is wrong with where it is kept: the
    function behind the one Custom::StackPolicy holds the stack and the policy itself, in
    STACK_ID and STACK_POLICY, and reads neither from the request."""
    resources = template.get("Resources", {})
    custom = [(name, resource) for name, resource in resources.items() if resource.get("Type") == "Custom::StackPolicy"]
    if len(custom) != 1:
        return None, [f"apiary.yaml has {len(custom)} Custom::StackPolicy resources, not one"]
    name, resource = custom[0]
    properties = resource.get("Properties", {})
    failures = []

    extra = sorted(set(properties) - {"ServiceToken", "ServiceTimeout"})
    if extra:
        failures.append(f"{name} passes {', '.join(extra)}: the function takes nothing from the request")

    token = properties.get("ServiceToken")
    function_name = token.get("Fn::GetAtt", [None])[0] if isinstance(token, dict) else None
    function = resources.get(function_name, {}) if isinstance(function_name, str) else {}
    if function.get("Type") != "AWS::Lambda::Function":
        return None, failures + [f"{name}'s ServiceToken is not a function of the template"]

    function_properties = function.get("Properties", {})
    variables = function_properties.get("Environment", {}).get("Variables", {})
    code = function_properties.get("Code", {}).get("ZipFile", "")
    if variables.get("STACK_ID") != {"Ref": "AWS::StackId"}:
        failures.append(f"{function_name}'s STACK_ID is not the stack's own id")
    if "ResourceProperties" in code:
        failures.append(f"{function_name} reads the request's ResourceProperties")
    for needed in ('os.environ["STACK_ID"]', 'os.environ["STACK_POLICY"]'):
        if needed not in code:
            failures.append(f"{function_name}'s code does not read {needed}")

    try:
        body = json.loads(variables.get("STACK_POLICY", ""))
    except (TypeError, json.JSONDecodeError):
        return None, failures + [f"{function_name} has no STACK_POLICY in JSON for the stack to set"]
    return body, failures


def check_policy():
    template = load(TEMPLATE)
    policy = json.loads(POLICY.read_text())
    resources = template.get("Resources", {})
    names, denied, failures = named(policy)

    for logical_id in sorted(names - resources.keys()):
        failures.append(f"stack-policy.json names {logical_id}, which apiary.yaml has no resource for")

    for logical_id in GUARDED:
        missing = {"Update:Replace", "Update:Delete"} - denied.get(logical_id, set())
        if missing:
            failures.append(f"stack-policy.json does not deny {', '.join(sorted(missing))} on {logical_id}")

    body, where = stack_policy_body(template)
    failures.extend(where)
    if body is not None and body != policy:
        failures.append("the stack sets another policy on itself than stack-policy.json")

    return failures


def texts(value):
    """Every text a value can take, one per branch of each Fn::If in it. A reference, which
    only the stack can resolve, counts as empty."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict) and len(value) == 1:
        ((function, argument),) = value.items()
        if function == "Fn::If":
            return texts(argument[1]) + texts(argument[2])
        if function == "Fn::Join":
            delimiter, parts = argument
            return [delimiter.join(choice) for choice in itertools.product(*(texts(part) for part in parts))]
        if function == "Fn::Sub":
            template, variables = (argument, {}) if isinstance(argument, str) else argument
            names = list(variables)
            results = []
            for choice in itertools.product(*(texts(variables[name]) for name in names)):
                given = dict(zip(names, choice))
                results.append(re.sub(r"\$\{([^}!]+)\}", lambda match: given.get(match.group(1), ""), template))
            return results
    return [""]


def check_outputs():
    failures = []
    for name, output in load(TEMPLATE).get("Outputs", {}).items():
        commands = [text for text in texts(output.get("Value")) if COMMAND.match(text)]
        if commands:
            failures.append(f"the {name} output is a command: {commands[0]}")
    return failures


STACK_UUID = {"Fn::Select": [2, {"Fn::Split": ["/", {"Ref": "AWS::StackId"}]}]}


def uses_stack_uuid(name):
    """Whether a resource's name is a Fn::Sub whose text uses a variable that is the whole
    UUID of the stack's ID. A new stack of the same name has a stack ID of its own."""
    if not isinstance(name, dict) or list(name) != ["Fn::Sub"]:
        return False
    argument = name["Fn::Sub"]
    if not (isinstance(argument, list) and len(argument) == 2):
        return False
    text, variables = argument
    if not (isinstance(text, str) and isinstance(variables, dict)):
        return False
    return any(value == STACK_UUID and "${" + variable + "}" in text for variable, value in variables.items())


def check_kept():
    template = load(TEMPLATE)
    resources = template.get("Resources", {})
    failures = []

    for logical_id in SECRETS:
        resource = resources.get(logical_id)
        if resource is None:
            failures.append(f"apiary.yaml has no {logical_id}")
            continue
        for attribute, kept in (("DeletionPolicy", "RetainExceptOnCreate"), ("UpdateReplacePolicy", "Retain")):
            if resource.get(attribute) != kept:
                failures.append(f"{logical_id} has {attribute} {resource.get(attribute)}, not {kept}")
        if not uses_stack_uuid(resource.get("Properties", {}).get("Name")):
            failures.append(
                f"{logical_id}'s name does not use the stack ID's UUID: "
                "a deleted stack's kept secret could block a new stack of the same name"
            )

    download_key = resources.get(DOWNLOAD_KEY)
    if download_key is None:
        failures.append(f"apiary.yaml has no {DOWNLOAD_KEY}, the download key's secret")
    else:
        for attribute in ("DeletionPolicy", "UpdateReplacePolicy"):
            if download_key.get(attribute) in RETAINED:
                failures.append(
                    f"{DOWNLOAD_KEY} has {attribute} {download_key[attribute]}: "
                    "the download key's secret is not kept"
                )

    for logical_id, resource in resources.items():
        if resource.get("Type") != "AWS::Logs::LogGroup":
            continue
        for attribute in ("DeletionPolicy", "UpdateReplacePolicy"):
            if resource.get(attribute) != "Retain":
                failures.append(f"{logical_id} has {attribute} {resource.get(attribute)}, not Retain")
        properties = resource.get("Properties", {})
        if "RetentionInDays" not in properties:
            failures.append(f"{logical_id} has no RetentionInDays: a kept log group would keep its events forever")
        if not uses_stack_uuid(properties.get("LogGroupName")):
            failures.append(
                f"{logical_id}'s name does not use the stack ID's UUID: "
                "a deleted stack's kept log group could block a new stack of the same name"
            )

    body, _where = stack_policy_body(template)
    policies = (("stack-policy.json", json.loads(POLICY.read_text())), ("the stack's own policy", body or {}))
    for where, policy in policies:
        if DOWNLOAD_KEY in named(policy)[0]:
            failures.append(f"{where} names {DOWNLOAD_KEY}: no stack policy guards the download key's secret")

    keys_secrets = json.dumps(template.get("Outputs", {}).get("KeysSecrets", {}))
    if DOWNLOAD_KEY in keys_secrets or "download-key" in keys_secrets:
        failures.append("the KeysSecrets output names the download key's secret")

    return failures


def find_in_maps(value):
    """The arguments of every Fn::FindInMap in a value."""
    if isinstance(value, dict):
        for function, argument in value.items():
            if function == "Fn::FindInMap":
                yield argument
            yield from find_in_maps(argument)
    elif isinstance(value, list):
        for item in value:
            yield from find_in_maps(item)


def check_mappings():
    template = load(TEMPLATE)
    mappings = template.get("Mappings", {})
    failures = []

    for name, keys in MAPPINGS.items():
        mapping = mappings.get(name, {})
        found = {key: set(values) for key, values in mapping.items()}
        if found != keys:
            failures.append(f"the {name} mapping holds {found or 'nothing'}, not {keys}")

    for argument in find_in_maps(template):
        names = argument[:3]
        if not all(isinstance(name, str) for name in names):
            failures.append(f"Fn::FindInMap {json.dumps(argument)} names its value by a reference")
            continue
        name, key, value = names
        if value not in mappings.get(name, {}).get(key, {}):
            failures.append(f"Fn::FindInMap [{name}, {key}, {value}] names no value of the mappings")

    return failures


EDITION = {"Ref": "Edition"}


def equals(value):
    """The arguments of every Fn::Equals in a value."""
    if isinstance(value, dict):
        for function, argument in value.items():
            if function == "Fn::Equals":
                yield argument
            yield from equals(argument)
    elif isinstance(value, list):
        for item in value:
            yield from equals(item)


def check_editions(paths):
    failures = []
    for path in paths:
        template = load(path)
        allowed = template.get("Parameters", {}).get("Edition", {}).get("AllowedValues", [])
        if not allowed:
            failures.append(f"{path}: Edition has no AllowedValues")
        compared = set()
        for argument in equals(template):
            if not (isinstance(argument, list) and EDITION in argument):
                continue
            others = [other for other in argument if other != EDITION]
            if len(others) != 1 or not isinstance(others[0], str):
                failures.append(f"{path}: Fn::Equals {json.dumps(argument)} compares Edition with no one value")
                continue
            compared.add(others[0])
            if others[0] not in allowed:
                failures.append(
                    f"{path}: Fn::Equals compares Edition with {others[0]!r}, "
                    f"not one of its AllowedValues {allowed}: it is never true"
                )
        for value in allowed:
            if value not in compared:
                failures.append(f"{path}: no Fn::Equals compares Edition with its AllowedValue {value!r}")
    return failures


def check_ascii(paths):
    failures = []
    for path in paths:
        for number, line in enumerate(Path(path).read_bytes().split(b"\n"), start=1):
            text = line.decode("utf-8", errors="replace")
            for column, character in enumerate(text, start=1):
                if not character.isascii():
                    name = unicodedata.name(character, "an unnamed character")
                    failures.append(f"{path}:{number}:{column}: U+{ord(character):04X} {name} is not ASCII")
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
    elif argv[1:] == ["outputs"]:
        failures = check_outputs()
    elif argv[1:] == ["kept"]:
        failures = check_kept()
    elif argv[1:] == ["mappings"]:
        failures = check_mappings()
    elif argv[1:2] == ["editions"]:
        failures = check_editions(argv[2:] or [TEMPLATE])
    elif argv[1:2] == ["ascii"]:
        failures = check_ascii(argv[2:] or [TEMPLATE, POLICY])
    elif len(argv) == 3 and argv[1] == "secrets":
        failures = check_secrets(argv[2])
    else:
        sys.exit(__doc__)

    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main(sys.argv)
