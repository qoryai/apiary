"""Tests of the AWS template's version lookup: the code of VersionFunction in
deploy/aws/apiary.yaml, taken from the template and run with the registry's HTTP calls and
boto3 stubbed.

    python3 -m unittest discover -s scripts -p "test_*.py"

The standard library alone: the template is read as text, and boto3 and botocore are stand-ins.
"""

import base64
import contextlib
import hashlib
import http.client
import io
import json
import sys
import types
import unittest
import urllib.error
import urllib.parse
import urllib.request
import urllib.response
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "deploy" / "aws" / "apiary.yaml"

COMMUNITY = "Qory Apiary Community"
PRO = "Qory Apiary Pro"
COMMUNITY_REPOSITORY = "ghcr.io/qoryai/apiary"
PRO_REPOSITORY = "ghcr.io/qoryai/apiary-pro"
STACK_ID = "arn:aws:cloudformation:us-east-1:123456789012:stack/qory/0a1b2c3d-4e5f-11f0-8a9b-0c1d2e3f4a5b"
SECRET_ARN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:qory/download-key-AbCdEf"
USERNAME = "example-account"
PASSWORD = "ghp_examplepassword0123456789"
TOKEN = "registry-token-0123456789abcdef"
RESPONSE_URL = "https://cloudformation-custom-resource-response.example.com/response"
ACCEPTED = [
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
]


def digest_of(version):
    return "sha256:" + hashlib.sha256(version.encode()).hexdigest()


def function_code():
    """The code under VersionFunction's ZipFile, as Lambda gets it."""
    lines = TEMPLATE.read_text(encoding="utf-8").split("\n")
    start = lines.index("  VersionFunction:")
    zip_line = next(index for index in range(start, len(lines)) if lines[index].strip() == "ZipFile: |")
    indent = len(lines[zip_line]) - len(lines[zip_line].lstrip()) + 2
    code = []
    for line in lines[zip_line + 1 :]:
        if line.strip() and not line.startswith(" " * indent):
            break
        code.append(line[indent:])
    return "\n".join(code)


class Response(io.BytesIO):
    def __init__(self, body=b"", headers=None):
        super().__init__(body)
        self.headers = headers or {}


# Each stubbed HTTP error, closed after its test.
HTTP_ERRORS = []


def http_error(url, code):
    error = urllib.error.HTTPError(url, code, "refused", {}, io.BytesIO(b""))
    HTTP_ERRORS.append(error)
    return error


class Registry:
    """ghcr.io, as the function calls it: a token, pages of tags and manifests."""

    def __init__(self, pages=(), manifests=None):
        self.pages = list(pages)
        self.manifests = dict(manifests or {})
        self.token_error = None
        self.tags_error = None
        self.manifest_error = None
        self.link = None
        self.requests = []
        self.answers = []

    def urlopen(self, request, timeout=None):
        url = request.full_url
        headers = {key.lower(): value for key, value in request.header_items()}
        self.requests.append((request.get_method(), url, headers))
        if url == RESPONSE_URL:
            self.answers.append(json.loads(request.data))
            return Response()
        if url.startswith("https://ghcr.io/token?"):
            if self.token_error:
                raise self.token_error
            return Response(json.dumps({"token": TOKEN}).encode())
        if "/tags/list" in url:
            if self.tags_error:
                raise self.tags_error
            page = 0 if "last=" not in url else int(url.split("last=page")[1].split("&")[0])
            tags, link = self.pages[page], self.link
            if page + 1 < len(self.pages):
                path = url.split("https://ghcr.io")[1].split("?")[0]
                link = f'<{path}?last=page{page + 1}&n=1000>; rel="next"'
            return Response(json.dumps({"name": "x", "tags": tags}).encode(), {"Link": link} if link else {})
        if "/manifests/" in url:
            if self.manifest_error:
                raise self.manifest_error
            version = url.rsplit("/", 1)[1]
            if version not in self.manifests:
                raise http_error(url, 404)
            return Response(b"", {"Docker-Content-Digest": self.manifests[version]})
        raise AssertionError(f"an unexpected call: {url}")

    def calls(self, part):
        return [request for request in self.requests if part in request[1]]


class Aws:
    """boto3's two clients, as the function calls them."""

    def __init__(self, status="UPDATE_IN_PROGRESS"):
        self.status = status
        self.calls = []

    def client(self, name, config=None):
        aws = self

        class Client:
            def describe_stacks(self, StackName):
                aws.calls.append(("describe_stacks", StackName))
                return {"Stacks": [{"StackStatus": aws.status}]}

            def get_secret_value(self, SecretId):
                aws.calls.append(("get_secret_value", SecretId))
                return {"SecretString": json.dumps({"username": USERNAME, "password": PASSWORD})}

        return Client()


def load(aws):
    """The function's module, with boto3 and botocore's Config as stand-ins."""
    boto3 = types.ModuleType("boto3")
    boto3.client = aws.client
    botocore = types.ModuleType("botocore")
    config = types.ModuleType("botocore.config")
    config.Config = lambda **options: options
    module = types.ModuleType("version_function")
    with mock.patch.dict(sys.modules, {"boto3": boto3, "botocore": botocore, "botocore.config": config}):
        exec(compile(function_code(), "index.py", "exec"), module.__dict__)
    return module


class Context:
    log_stream_name = "2026/10/12/[$LATEST]0123456789abcdef"


def event(request="Create", edition=COMMUNITY, version="", template="", physical=None, secret=None):
    properties = {
        "ServiceToken": "arn:aws:lambda:us-east-1:123456789012:function:qory-VersionFunction",
        "ServiceTimeout": "360",
        "Edition": edition,
        "Repository": PRO_REPOSITORY if edition == PRO else COMMUNITY_REPOSITORY,
        "DownloadKeySecret": (SECRET_ARN if edition == PRO else "") if secret is None else secret,
        "Version": version,
        "LookForNewerRelease": "",
        "TemplateVersion": template,
        "DomainName": "qory.example.com",
    }
    result = {
        "RequestType": request,
        "ResponseURL": RESPONSE_URL,
        "StackId": STACK_ID,
        "RequestId": f"request-{request.lower()}",
        "LogicalResourceId": "Version",
        "ResourceType": "Custom::Version",
        "ResourceProperties": properties,
    }
    if physical is not None:
        result["PhysicalResourceId"] = physical
    return result


def physical_id(version):
    return f"{version}@{digest_of(version)}/request-create"


class Lookup(unittest.TestCase):
    def setUp(self):
        self.registry = Registry(
            pages=[["0.1.0", "0.2.0", "0.3.0", "latest"]],
            manifests={version: digest_of(version) for version in ("0.1.0", "0.2.0", "0.3.0")},
        )
        self.aws = Aws()
        self.environment = mock.patch.dict(
            "os.environ",
            {"STACK_ID": STACK_ID},
        )
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.addCleanup(self.close_http_errors)

    def close_http_errors(self):
        while HTTP_ERRORS:
            HTTP_ERRORS.pop().close()

    def run_function(self, request):
        """The function's answer to one request, its log in self.log."""
        self.registry.requests.clear()
        self.registry.answers.clear()
        module = load(self.aws)
        output = io.StringIO()
        with (
            mock.patch.object(module.OPENER, "open", self.registry.urlopen),
            mock.patch("urllib.request.urlopen", self.registry.urlopen),
            contextlib.redirect_stdout(output),
        ):
            module.handler(request, Context())
        self.log = output.getvalue()
        self.assertEqual(len(self.registry.answers), 1)
        self.body = self.registry.requests[-1]
        return self.registry.answers[0]

    def assert_failed(self, answer, reason):
        self.assertEqual(answer["Status"], "FAILED")
        self.assertEqual(answer["Reason"], reason)
        self.assertEqual(answer["Data"], {})
        self.assertIn(reason, self.log)

    # The newest release.

    def test_the_newest_release_is_the_highest_x_y_z_as_integers(self):
        tags = ["latest", "next", "0.9.0", "0.10.0", "0.10.1", "v1.0.0", "1.0", "1.0.0-rc1", "sha-abc1234", "01.2.3", "2.0.0.1", "0.10.1 "]
        self.registry.pages = [tags]
        self.registry.manifests = {"0.10.1": digest_of("0.10.1")}
        answer = self.run_function(event())
        self.assertEqual(answer["Status"], "SUCCESS", answer)
        self.assertEqual(answer["Data"]["Version"], "0.10.1")
        self.assertEqual(answer["Data"]["Digest"], digest_of("0.10.1"))
        self.assertEqual(answer["Data"]["Image"], f"{COMMUNITY_REPOSITORY}@{digest_of('0.10.1')}")
        self.assertNotIn("latest", [url.rsplit("/", 1)[1] for _method, url, _headers in self.registry.calls("/manifests/")])

    def test_latest_alone_is_no_release(self):
        self.registry.pages = [["latest", "0.3", "sha-abc1234", "next"]]
        answer = self.run_function(event())
        self.assert_failed(answer, f"No release of {COMMUNITY} was found at {COMMUNITY_REPOSITORY}.")

    def test_every_page_of_tags_is_read(self):
        self.registry.pages = [["0.1.0", "0.2.0"], ["0.9.0", "latest"], ["0.10.0"]]
        self.registry.manifests["0.10.0"] = digest_of("0.10.0")
        answer = self.run_function(event())
        self.assertEqual(answer["Data"]["Version"], "0.10.0")
        urls = [url for _method, url, _headers in self.registry.calls("/tags/list")]
        self.assertEqual(
            urls,
            [
                "https://ghcr.io/v2/qoryai/apiary/tags/list?n=1000",
                "https://ghcr.io/v2/qoryai/apiary/tags/list?last=page1&n=1000",
                "https://ghcr.io/v2/qoryai/apiary/tags/list?last=page2&n=1000",
            ],
        )

    def test_a_next_page_outside_the_repository_tags_is_refused(self):
        for link in (
            '</v2/qoryai/other/tags/list?last=0.1.0&n=1000>; rel="next"',
            '</v2/qoryai/apiary-pro/tags/list?last=0.1.0&n=1000>; rel="next"',
            '</v2/qoryai/apiary/manifests/latest>; rel="next"',
            '</v2/qoryai/apiary/tags/list/../../other/tags/list?n=1000>; rel="next"',
            '<https://ghcr.io/v2/qoryai/other/tags/list?n=1000>; rel="next"',
        ):
            with self.subTest(link=link):
                self.registry.link = link
                answer = self.run_function(event())
                self.assert_failed(answer, "ghcr.io could not be reached to find the version: update again later.")
                self.assertEqual(len(self.registry.calls("/tags/list")), 1)

    def test_the_digest_is_asked_for_by_a_head_accepting_indexes_and_manifests(self):
        self.run_function(event())
        ((method, url, headers),) = self.registry.calls("/manifests/")
        self.assertEqual((method, url), ("HEAD", "https://ghcr.io/v2/qoryai/apiary/manifests/0.3.0"))
        self.assertEqual([kind.strip() for kind in headers["accept"].split(",")], ACCEPTED)
        self.assertEqual(headers["authorization"], f"Bearer {TOKEN}")

    # A typed version.

    def test_a_typed_version_goes_straight_to_its_manifest(self):
        answer = self.run_function(event(version="0.2.0"))
        self.assertEqual(answer["Status"], "SUCCESS", answer)
        self.assertEqual(answer["Data"], {"Version": "0.2.0", "Image": f"{COMMUNITY_REPOSITORY}@{digest_of('0.2.0')}", "Digest": digest_of("0.2.0")})
        self.assertEqual(self.registry.calls("/tags/list"), [])

    def test_message_2_a_typed_version_that_does_not_exist(self):
        answer = self.run_function(event(edition=PRO, version="0.9.9"))
        self.assert_failed(answer, f"{PRO} 0.9.9 does not exist: check Version, or leave it empty for the newest release.")

    def test_a_typed_version_that_is_not_x_y_z_does_not_exist(self):
        for typed in ("latest", "0.3", "v0.3.0", "0.3.0/../x"):
            with self.subTest(typed=typed):
                answer = self.run_function(event(version=typed))
                self.assert_failed(answer, f"{COMMUNITY} {typed} does not exist: check Version, or leave it empty for the newest release.")
                self.assertEqual(self.registry.calls("/manifests/"), [])

    # The registry's answers.

    def test_message_1_no_release_found(self):
        for pages, tags_error in (([[]], None), ([["latest"]], None), ([[]], "404")):
            with self.subTest(pages=pages, tags_error=tags_error):
                self.registry.pages = pages
                self.registry.tags_error = http_error("tags", 404) if tags_error else None
                answer = self.run_function(event(edition=PRO))
                self.assert_failed(answer, f"No release of {PRO} was found at {PRO_REPOSITORY}.")

    def test_message_3_the_key_cannot_read_the_package(self):
        for code in (401, 403):
            for where in ("token_error", "tags_error", "manifest_error"):
                with self.subTest(code=code, where=where):
                    self.registry.token_error = self.registry.tags_error = self.registry.manifest_error = None
                    setattr(self.registry, where, http_error("x", code))
                    answer = self.run_function(event(edition=PRO))
                    self.assert_failed(answer, "The download key cannot read ghcr.io/qoryai/apiary-pro: check Qory Apiary Pro download key.")

    def test_message_4_the_image_cannot_be_read_without_a_key(self):
        for code in (401, 403):
            with self.subTest(code=code):
                self.registry.tags_error = http_error("x", code)
                answer = self.run_function(event())
                self.assert_failed(answer, "ghcr.io/qoryai/apiary cannot be read without a download key that reads it.")

    def test_message_5_the_registry_cannot_be_reached(self):
        for error in (urllib.error.URLError("down"), TimeoutError("slow"), http_error("x", 500), http_error("x", 503)):
            with self.subTest(error=error):
                self.registry.token_error = error
                answer = self.run_function(event())
                self.assert_failed(answer, "ghcr.io could not be reached to find the version: update again later.")

    def test_message_6_a_typed_version_older_than_the_one_the_stack_runs(self):
        answer = self.run_function(event("Update", version="0.2.0", physical=physical_id("0.3.0")))
        self.assert_failed(answer, "Version 0.2.0 is older than the 0.3.0 the stack runs: Qory Apiary does not go back to an older version.")
        self.assertEqual(answer["PhysicalResourceId"], physical_id("0.3.0"))

    def test_older_is_by_integers(self):
        answer = self.run_function(event("Update", version="0.9.0", physical=physical_id("0.10.0")))
        self.assertEqual(answer["Status"], "FAILED")
        self.assertIn("Version 0.9.0 is older than the 0.10.0", answer["Reason"])

    def test_a_create_is_never_refused_as_older_a_restore_included(self):
        answer = self.run_function(event("Create", version="0.1.0"))
        self.assertEqual(answer["Status"], "SUCCESS", answer)
        self.assertEqual(answer["Data"]["Version"], "0.1.0")

    def test_the_same_or_a_newer_typed_version_is_not_refused(self):
        for typed in ("0.3.0", "0.3.1"):
            with self.subTest(typed=typed):
                self.registry.manifests["0.3.1"] = digest_of("0.3.1")
                answer = self.run_function(event("Update", version=typed, physical=physical_id("0.3.0")))
                self.assertEqual(answer["Status"], "SUCCESS", answer)

    def test_message_7_a_release_of_a_newer_minor_than_the_template(self):
        self.registry.pages = [["0.3.0", "0.4.0"]]
        self.registry.manifests["0.4.0"] = digest_of("0.4.0")
        for edition in (PRO, COMMUNITY):
            for typed in ("", "0.4.0"):
                with self.subTest(edition=edition, typed=typed):
                    answer = self.run_function(event(edition=edition, version=typed, template="0.3.2"))
                    self.assert_failed(answer, f"{edition} 0.4.0 needs a newer template: update the stack with the newest apiary.yaml.")

    def test_a_newer_major_needs_a_newer_template_too(self):
        self.registry.pages = [["0.3.0", "1.0.0"]]
        self.registry.manifests["1.0.0"] = digest_of("1.0.0")
        answer = self.run_function(event(template="0.3.0"))
        self.assertEqual(answer["Reason"], f"{COMMUNITY} 1.0.0 needs a newer template: update the stack with the newest apiary.yaml.")

    def test_a_patch_or_an_older_minor_fits_the_template(self):
        self.registry.pages = [["0.3.0", "0.3.7"]]
        self.registry.manifests["0.3.7"] = digest_of("0.3.7")
        for template in ("0.3.0", "0.4.0", "0.10.0", ""):
            with self.subTest(template=template):
                answer = self.run_function(event(template=template))
                self.assertEqual(answer["Status"], "SUCCESS", answer)
                self.assertEqual(answer["Data"]["Version"], "0.3.7")

    # The key: Qory Apiary Pro's lookup alone uses it.

    def test_qory_apiary_pro_asks_for_the_token_with_the_key_from_the_secret(self):
        self.run_function(event(edition=PRO))
        self.assertIn(("get_secret_value", SECRET_ARN), self.aws.calls)
        ((_method, url, headers),) = self.registry.calls("/token?")
        self.assertEqual(url, "https://ghcr.io/token?service=ghcr.io&scope=repository:qoryai/apiary-pro:pull")
        self.assertEqual(headers["authorization"], "Basic " + base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode())

    def test_qory_apiary_community_asks_for_the_token_anonymously(self):
        self.run_function(event())
        self.assertNotIn("get_secret_value", [name for name, _argument in self.aws.calls])
        ((_method, url, headers),) = self.registry.calls("/token?")
        self.assertEqual(url, "https://ghcr.io/token?service=ghcr.io&scope=repository:qoryai/apiary:pull")
        self.assertNotIn("authorization", headers)

    def assert_no_secret(self, answer):
        body = json.dumps(answer)
        basic = base64.b64encode(f"{USERNAME}:{PASSWORD}".encode()).decode()
        for secret in (USERNAME, PASSWORD, TOKEN, basic):
            self.assertNotIn(secret, self.log)
            self.assertNotIn(secret, body)
        # Nor the request: its stack, its response URL or its properties.
        for part in (STACK_ID, RESPONSE_URL, SECRET_ARN, "qory.example.com"):
            self.assertNotIn(part, self.log)

    def test_the_key_and_the_token_are_never_logged_or_answered(self):
        for name, error in (("found", None), ("refused", http_error("x", 403)), ("missing", http_error("x", 404))):
            with self.subTest(case=name):
                self.registry.manifest_error = error
                self.assert_no_secret(self.run_function(event(edition=PRO)))

    def test_an_unexpected_failure_logs_its_error_without_the_key_or_the_token(self):
        answer_registry = self.registry.urlopen

        def leaky(request, timeout=None):
            if "/manifests/" in request.full_url:
                raise RuntimeError(f"refused {dict(request.header_items())} for {USERNAME} {PASSWORD}")
            return answer_registry(request, timeout)

        self.registry.urlopen = leaky
        answer = self.run_function(event(edition=PRO))
        self.assertEqual(answer["Status"], "FAILED")
        self.assertEqual(answer["Reason"], f"See the details in CloudWatch Log Stream: {Context.log_stream_name}")
        self.assertIn("The version was not found: RuntimeError: refused", self.log)
        self.assertIn("***", self.log)
        self.assert_no_secret(answer)

    # Create, update, rollback and delete.

    def test_a_create_and_each_update_answer_with_a_new_id_naming_the_version_and_digest(self):
        create = self.run_function(event("Create"))
        self.assertEqual(create["PhysicalResourceId"], physical_id("0.3.0"))
        first = self.run_function(dict(event("Update", physical=create["PhysicalResourceId"]), RequestId="request-1"))
        second = self.run_function(dict(event("Update", physical=first["PhysicalResourceId"]), RequestId="request-2"))
        ids = {create["PhysicalResourceId"], first["PhysicalResourceId"], second["PhysicalResourceId"]}
        self.assertEqual(len(ids), 3)
        for answer in (first, second):
            self.assertTrue(answer["PhysicalResourceId"].startswith(f"0.3.0@{digest_of('0.3.0')}/"))
            self.assertEqual(answer["Data"]["Digest"], digest_of("0.3.0"))
        self.assertEqual([call for call in self.aws.calls if call[0] == "describe_stacks"], [("describe_stacks", STACK_ID)] * 2)

    def test_an_update_while_the_stack_rolls_back_answers_with_the_id_it_is_given(self):
        self.aws.status = "UPDATE_ROLLBACK_IN_PROGRESS"
        self.registry.pages = [["0.4.0"]]
        answer = self.run_function(event("Update", edition=PRO, version="0.2.0", physical=physical_id("0.3.0")))
        self.assertEqual(answer["Status"], "SUCCESS", answer)
        self.assertEqual(answer["PhysicalResourceId"], physical_id("0.3.0"))
        self.assertEqual(
            answer["Data"], {"Version": "0.3.0", "Image": f"{PRO_REPOSITORY}@{digest_of('0.3.0')}", "Digest": digest_of("0.3.0")}
        )
        self.assertEqual(self.registry.requests[:-1], [])
        self.assertNotIn("get_secret_value", [name for name, _argument in self.aws.calls])

    def test_a_delete_changes_nothing(self):
        answer = self.run_function(event("Delete", physical=physical_id("0.3.0")))
        self.assertEqual(answer["Status"], "SUCCESS")
        self.assertEqual(answer["PhysicalResourceId"], physical_id("0.3.0"))
        self.assertEqual(self.registry.requests[:-1], [])
        self.assertEqual(self.aws.calls, [])

    def test_a_failed_update_keeps_the_id_it_is_given(self):
        self.registry.token_error = urllib.error.URLError("down")
        answer = self.run_function(event("Update", physical=physical_id("0.3.0")))
        self.assertEqual(answer["Status"], "FAILED")
        self.assertEqual(answer["PhysicalResourceId"], physical_id("0.3.0"))

    def test_the_answer_is_put_to_the_response_url_well_under_4096_bytes(self):
        answer = self.run_function(event(edition=PRO))
        method, url, _headers = self.body
        self.assertEqual((method, url), ("PUT", RESPONSE_URL))
        self.assertEqual(
            set(answer), {"Status", "Reason", "PhysicalResourceId", "StackId", "RequestId", "LogicalResourceId", "Data"}
        )
        self.assertLess(len(json.dumps(answer).encode()), 4096)
        long = self.run_function(event(edition=PRO, version="9" * 3000))
        self.assertLess(len(json.dumps(long).encode()), 4096)


class Redirects(unittest.TestCase):
    """The function's calls through urllib's real handlers, the network stubbed below them:
    a redirect from ghcr.io is never followed, so the key and the token never leave it."""

    LOCATIONS = (
        "https://attacker.example/steal",
        "http://attacker.example/steal",
        "http://ghcr.io/v2/qoryai/apiary-pro/tags/list?n=1000",
    )

    def setUp(self):
        self.aws = Aws()
        environment = mock.patch.dict("os.environ", {"STACK_ID": STACK_ID})
        environment.start()
        self.addCleanup(environment.stop)

    def network(self, stage, location):
        """http_open and https_open: ghcr.io answers, but at stage with a 302 to location."""
        sent, answers = [], []

        def answer(request, code=200, body=b"", headers=()):
            message = http.client.HTTPMessage()
            for key, value in headers:
                message[key] = value
            response = urllib.response.addinfourl(io.BytesIO(body), message, request.full_url, code)
            response.msg = "Found" if code == 302 else "OK"
            return response

        def open_(handler, request):
            url = urllib.parse.urlsplit(request.full_url)
            headers = {key.lower(): value for key, value in request.header_items()}
            sent.append((url.scheme, url.hostname, request.full_url, headers))
            if request.full_url == RESPONSE_URL:
                answers.append(json.loads(request.data))
                return answer(request)
            if (url.scheme, url.hostname) != ("https", "ghcr.io"):
                return answer(request, body=json.dumps({"token": "x", "tags": ["9.9.9"]}).encode())
            if stage in url.path:
                return answer(request, 302, headers=[("Location", location)])
            if url.path == "/token":
                return answer(request, body=json.dumps({"token": TOKEN}).encode())
            if url.path.endswith("/tags/list"):
                return answer(request, body=json.dumps({"tags": ["0.3.0"]}).encode())
            return answer(request, headers=[("Docker-Content-Digest", digest_of("0.3.0"))])

        return open_, sent, answers

    def test_a_redirect_is_never_followed_and_no_credential_leaves_ghcr_io(self):
        for stage in ("/token", "/tags/list", "/manifests/"):
            for location in self.LOCATIONS:
                with self.subTest(stage=stage, location=location):
                    open_, sent, answers = self.network(stage, location)
                    module = load(self.aws)
                    with (
                        mock.patch.object(urllib.request.HTTPSHandler, "https_open", open_),
                        mock.patch.object(urllib.request.HTTPHandler, "http_open", open_),
                        contextlib.redirect_stdout(io.StringIO()),
                    ):
                        module.handler(event(edition=PRO), Context())
                    self.assertEqual(len(answers), 1)
                    self.assertEqual(answers[0]["Status"], "FAILED")
                    self.assertEqual(answers[0]["Reason"], "ghcr.io could not be reached to find the version: update again later.")
                    for scheme, host, url, headers in sent:
                        if "authorization" in headers:
                            self.assertEqual((scheme, host), ("https", "ghcr.io"), url)
                    self.assertNotIn(location, [url for _scheme, _host, url, _headers in sent])

    def test_without_a_redirect_the_same_network_installs(self):
        open_, sent, answers = self.network("/none/", "")
        module = load(self.aws)
        with (
            mock.patch.object(urllib.request.HTTPSHandler, "https_open", open_),
            mock.patch.object(urllib.request.HTTPHandler, "http_open", open_),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            module.handler(event(edition=PRO), Context())
        self.assertEqual(answers[0]["Status"], "SUCCESS", answers[0])
        self.assertEqual(answers[0]["Data"]["Version"], "0.3.0")


if __name__ == "__main__":
    unittest.main()
