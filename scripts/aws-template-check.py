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
sets on itself is the same as the file's. A renamed resource would otherwise lose its guard
without a word. That policy is the STACK_POLICY of the function the template's one rule on
CloudFormation's stack status changes targets, and nothing else does: the rule is enabled,
on the default event bus, matches the source aws.cloudformation, the detail-type
"CloudFormation Stack Status Change", this stack's own id under detail.stack-id and the
statuses CREATE_COMPLETE, UPDATE_COMPLETE and UPDATE_ROLLBACK_COMPLETE under
detail.status-details.status, and nothing more. The function's STACK_ID is the stack's own
id, and its code checks the event's stack and status again. One Lambda permission lets
events.amazonaws.com invoke it, from that rule alone. Its role is trusted by Lambda alone
and allows cloudformation:SetStackPolicy on this stack and writing to the function's own
log group, nothing else. And no function sets a stack policy from inside the stack's create
or update, where CloudFormation refuses it: no custom resource's function, and no function
but the rule's target, calls set_stack_policy, and no other role allows
cloudformation:SetStackPolicy.

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
template): every Fn::Equals that has !Ref Edition as one of its two arguments, anywhere in
the template, however deep in a Fn::And, Fn::Or or Fn::Not, has as its other argument a
plain text that is one of Edition's AllowedValues; each AllowedValue is so compared at
least once; and under Rules and Conditions, !Ref Edition is used nowhere else than as one
of the two arguments of a Fn::Equals (not in a Fn::Contains, for one), each other use named
by where it is. A comparison with a value Edition no longer allows is never true, so the
Rule or Condition it decides stops applying, and cfn-lint does not say so.

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


STACK_ID = {"Ref": "AWS::StackId"}
STACK_STATUS_CHANGE = "CloudFormation Stack Status Change"
COMPLETE = {"CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_ROLLBACK_COMPLETE"}
CUSTOM_RESOURCE = re.compile(r"^(Custom::.+|AWS::CloudFormation::CustomResource)$")
SETS_STACK_POLICY = re.compile(r"set_stack_policy|SetStackPolicy")


def get_att(value, attribute="Arn"):
    """The logical ID a !GetAtt <id>.<attribute> names, or None."""
    if isinstance(value, dict) and list(value) == ["Fn::GetAtt"]:
        argument = value["Fn::GetAtt"]
        if isinstance(argument, str):
            argument = argument.split(".", 1)
        if isinstance(argument, list) and len(argument) == 2 and argument[1] == attribute:
            return argument[0]
    return None


def of_type(resources, kind):
    return {name: resource for name, resource in resources.items() if resource.get("Type") == kind}


def statements(role):
    """Every statement of a role's inline policies."""
    for policy in role.get("Properties", {}).get("Policies", []):
        yield from as_list(policy.get("PolicyDocument", {}).get("Statement", []))


def allows_set_stack_policy(role):
    return any(
        statement.get("Effect") == "Allow"
        and any(action in ("cloudformation:SetStackPolicy", "cloudformation:*", "*") for action in as_list(statement.get("Action")))
        for statement in statements(role)
    )


def check_role(name, role, log_group):
    """The function's role: trusted by Lambda alone, allowing cloudformation:SetStackPolicy
    on this stack and writing to its own log group, and nothing else."""
    failures = []
    if role.get("Type") != "AWS::IAM::Role":
        return [f"the stack policy's function has no role of the template's ({name})"]
    properties = role.get("Properties", {})
    trust = as_list(properties.get("AssumeRolePolicyDocument", {}).get("Statement", []))
    if trust != [{"Effect": "Allow", "Principal": {"Service": "lambda.amazonaws.com"}, "Action": "sts:AssumeRole"}]:
        failures.append(f"{name} is trusted by another than lambda.amazonaws.com alone")
    for extra in ("ManagedPolicyArns", "PermissionsBoundary"):
        if extra in properties:
            failures.append(f"{name} has {extra}: its inline policy alone says what it may do")
    found = sorted(
        (statement.get("Effect"), sorted(as_list(statement.get("Action"))), json.dumps(statement.get("Resource"), sort_keys=True))
        for statement in statements(role)
    )
    wanted = sorted(
        [
            ("Allow", ["cloudformation:SetStackPolicy"], json.dumps(STACK_ID)),
            ("Allow", ["logs:CreateLogStream", "logs:PutLogEvents"], json.dumps({"Fn::GetAtt": [log_group, "Arn"]})),
        ]
    )
    if found != wanted:
        failures.append(
            f"{name} allows other than cloudformation:SetStackPolicy on this stack and writing to "
            f"{log_group}: {json.dumps(found)}"
        )
    return failures


def stack_policy_body(template):
    """The policy the stack sets on itself, and what is wrong with how it sets it: the one
    rule on CloudFormation's stack status changes, filtered to this stack and to its
    completed creates and updates, targets one function, which holds the stack and the
    policy itself, in STACK_ID and STACK_POLICY; one permission lets that rule alone invoke
    it; and its role may set this stack's policy and write its log, nothing else."""
    resources = template.get("Resources", {})
    rules = {
        name: rule
        for name, rule in of_type(resources, "AWS::Events::Rule").items()
        if "aws.cloudformation" in json.dumps(rule.get("Properties", {}).get("EventPattern", {}))
    }
    if len(rules) != 1:
        return None, [f"apiary.yaml has {len(rules)} rules on aws.cloudformation events, not one"]
    (rule_name, rule), = rules.items()
    properties = rule.get("Properties", {})
    failures = []

    if properties.get("State") != "ENABLED":
        failures.append(f"{rule_name} is not ENABLED")
    if properties.get("EventBusName", "default") != "default":
        failures.append(f"{rule_name} is not on the default event bus, where CloudFormation sends its events")
    wanted_pattern = {
        "source": ["aws.cloudformation"],
        "detail-type": [STACK_STATUS_CHANGE],
        "detail": {"stack-id": [STACK_ID], "status-details": {"status": sorted(COMPLETE)}},
    }
    pattern = properties.get("EventPattern", {})
    found_pattern = json.loads(json.dumps(pattern))
    try:
        found_pattern["detail"]["status-details"]["status"] = sorted(found_pattern["detail"]["status-details"]["status"])
    except (KeyError, TypeError):
        pass
    if found_pattern != wanted_pattern:
        failures.append(
            f"{rule_name}'s pattern is not this stack's {STACK_STATUS_CHANGE} to "
            f"{', '.join(sorted(COMPLETE))} alone: {json.dumps(pattern)}"
        )

    targets = properties.get("Targets", [])
    function_name = get_att(targets[0].get("Arn")) if len(targets) == 1 else None
    function = resources.get(function_name, {}) if function_name else {}
    if function.get("Type") != "AWS::Lambda::Function":
        return None, failures + [f"{rule_name} has not one target, a function of the template"]
    if set(targets[0]) - {"Id", "Arn"}:
        failures.append(f"{rule_name}'s target passes the function more than the event")

    permissions = {
        name: permission.get("Properties", {})
        for name, permission in of_type(resources, "AWS::Lambda::Permission").items()
        if function_name in json.dumps(permission.get("Properties", {}).get("FunctionName"))
    }
    wanted_permission = {
        "FunctionName": {"Fn::GetAtt": [function_name, "Arn"]},
        "Action": "lambda:InvokeFunction",
        "Principal": "events.amazonaws.com",
        "SourceArn": {"Fn::GetAtt": [rule_name, "Arn"]},
    }
    if list(permissions.values()) != [wanted_permission]:
        failures.append(
            f"{function_name} may be invoked by other than {rule_name} alone: "
            f"its permissions are {json.dumps(permissions)}"
        )

    function_properties = function.get("Properties", {})
    log_group = function_properties.get("LoggingConfig", {}).get("LogGroup", {})
    log_group = log_group.get("Ref") if isinstance(log_group, dict) else None
    if not log_group or resources.get(log_group, {}).get("Type") != "AWS::Logs::LogGroup":
        failures.append(f"{function_name} does not log to a log group of the template's")
    role_name = get_att(function_properties.get("Role"))
    failures.extend(check_role(role_name, resources.get(role_name, {}), log_group))

    variables = function_properties.get("Environment", {}).get("Variables", {})
    code = function_properties.get("Code", {}).get("ZipFile", "")
    if variables.get("STACK_ID") != STACK_ID:
        failures.append(f"{function_name}'s STACK_ID is not the stack's own id")
    for needed in (
        'os.environ["STACK_ID"]',
        'os.environ["STACK_POLICY"]',
        '"stack-id"',
        '"status-details"',
        *(f'"{status}"' for status in sorted(COMPLETE)),
    ):
        if needed not in code:
            failures.append(f"{function_name}'s code does not check or read {needed}")
    if "ResponseURL" in code or "ResourceProperties" in code:
        failures.append(f"{function_name} answers a custom resource: CloudFormation refuses its call during the create")

    try:
        body = json.loads(variables.get("STACK_POLICY", ""))
    except (TypeError, json.JSONDecodeError):
        return None, failures + [f"{function_name} has no STACK_POLICY in JSON for the stack to set"]
    return body, failures


def check_no_policy_in_progress(template, rule_target):
    """CloudFormation refuses SetStackPolicy while the stack's own create or update is in
    progress, so nothing inside them may call it: no custom resource's function, and no
    function but the rule's target, calls set_stack_policy, and no other role allows it."""
    resources = template.get("Resources", {})
    failures = []
    functions = of_type(resources, "AWS::Lambda::Function")
    for name, resource in resources.items():
        if not CUSTOM_RESOURCE.match(resource.get("Type", "")):
            continue
        function_name = get_att(resource.get("Properties", {}).get("ServiceToken"))
        code = functions.get(function_name, {}).get("Properties", {}).get("Code", {}).get("ZipFile", "")
        if SETS_STACK_POLICY.search(code) or function_name == rule_target:
            failures.append(
                f"{name} is a custom resource whose function sets the stack policy: "
                "CloudFormation refuses SetStackPolicy while the stack is in progress, and the create fails"
            )
    for name, function in functions.items():
        if name != rule_target and SETS_STACK_POLICY.search(function.get("Properties", {}).get("Code", {}).get("ZipFile", "")):
            failures.append(f"{name} calls set_stack_policy, and is not the target of the rule on the stack's completions")
    allowed = {get_att(functions.get(rule_target, {}).get("Properties", {}).get("Role"))}
    for name, role in of_type(resources, "AWS::IAM::Role").items():
        if name not in allowed and allows_set_stack_policy(role):
            failures.append(f"{name} allows cloudformation:SetStackPolicy: only the stack policy function's role may")
    return failures


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

    rule_targets = [
        get_att(target.get("Arn"))
        for rule in of_type(resources, "AWS::Events::Rule").values()
        if "aws.cloudformation" in json.dumps(rule.get("Properties", {}).get("EventPattern", {}))
        for target in rule.get("Properties", {}).get("Targets", [])
    ]
    failures.extend(check_no_policy_in_progress(template, rule_targets[0] if len(rule_targets) == 1 else None))

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


def stray_editions(value, where):
    """Where a value uses !Ref Edition other than as one of the two arguments of a
    Fn::Equals."""
    if value == EDITION:
        yield where
    elif isinstance(value, dict):
        for function, argument in value.items():
            if function == "Fn::Equals" and isinstance(argument, list) and len(argument) == 2:
                for index, item in enumerate(argument):
                    if item != EDITION:
                        yield from stray_editions(item, f"{where}.Fn::Equals[{index}]")
            else:
                yield from stray_editions(argument, f"{where}.{function}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from stray_editions(item, f"{where}[{index}]")


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
        for section in ("Rules", "Conditions"):
            for where in stray_editions(template.get(section, {}), section):
                failures.append(
                    f"{path}: {where} uses !Ref Edition other than as an argument of a Fn::Equals, "
                    "which this check cannot hold to Edition's AllowedValues"
                )
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
