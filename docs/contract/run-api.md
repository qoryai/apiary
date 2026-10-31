# The run API

A run, an agent on a machine, uses the run API to read its work item and the work
item's artifacts, and to push artifacts and its verdict. Each request is signed with the
access key of the gateway the run goes through; the run has no access key.

The run API is part of the feature `workflow_model`, which is off by default. On an
instance without the feature, a request that verifies gets `404` with the error page,
signed: the same body and type as a path the router does not know. A request without
a signature gets the `404` of a path the router does not know.

The code is in `lib/apiary_web/contract/run_api/`.

## Requests

Every path is under `/v1/runs/<run_id>/`, where `<run_id>` is the run's id as the run's
documents contain it. Qory Apiary identifies the run by this run id, under the gateway's
access key: the gateway sends only the id of a run it serves, and a request for a run
the key does not serve gets `404` `not_found`.

| Method and path | What it returns |
|---|---|
| `GET work-item` | The work item as the run reads it (the work item snapshot) |
| `GET artifacts` | The work item's artifacts with their versions (the index) |
| `GET artifacts/<version_id>/files/<filename>` | One file of one version, as a download |
| `POST artifacts` | Stores a new version of an artifact; returns the version |
| `POST verdict` | Stores the run's verdict as a version of the `verdict` artifact |

### Signing and the order of checks

A request is signed as a request to the run endpoint is (`ApiaryWeb.Contract.SignedRequest`,
`guides/contract.md`): `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`,
`X-Qory-Contract-Version: 1` and `X-Qory-Signature-Ed25519` under the gateway's access
key; a GET also signs `X-Qory-Timestamp`, and a POST signs its raw body. A POST has
`Content-Type: application/json`. A request sends no `Accept` header, or one that
accepts `application/json`, the file request included; any other gets `406`, unsigned.
Requests spend the run endpoint's bucket of the key's
rate limit. Every answer to a request that verifies is signed, except a `401`.

Before any check, the body of a POST is read, and each of these is `413`
`payload_too_large`, unsigned: a `Content-Length` over 32 MiB, before a byte is read; a
body over 64 KiB whose `X-Qory-Access-Key-Id` is not the key id of an active access key
of a gateway, after its first 64 KiB; and any body over 32 MiB.

The checks run in this order:

1. The checks of every signed request: `415`, `400` `bad_request` for a header sent
   twice, `401`, `429` `rate_limited`, `400` `bad_request` for an instance id absent or
   malformed, `400` `unsupported_contract_version`, and for a GET a timestamp outside
   300 seconds, `401`.
2. Without the feature `workflow_model`: `404`, the error page.
3. The run. The key must be a key of the gateway the run goes through, listed in the
   run's run key, from the instance that attached the run, of a gateway that may still
   serve the run's workspace; and the run must be a run of a work item. Any other case
   is `404` `not_found`, the same answer whatever the cause.
4. For a POST: a run that is no longer pending or running, whose sending has ended, or
   whose run of the workspace's queue has ended, is `409` `run_ended`. A run reads its work item after it ends; it writes nothing.
5. The checks listed with each request below.

An error is a JSON object with `error`, the code. Some errors also have `type`,
`limit`, `names` or `message`, as listed in the table of errors.

## GET work-item

Returns `200` with the work item snapshot:

```json
{
  "version": 1,
  "work_item": {"id": "wi_...", "number": 12, "url": "https://..."},
  "run": {"id": "<run_id>", "workflow": "capture-demo", "round": 2},
  "stage": {"id": "st_...", "name": "Build", "round": 2, "rounds": 3, "state": "running"},
  "inputs": [
    {"type": "acceptance-criteria", "required": true, "version": {"id": "av_...", "number": 2}}
  ],
  "outputs": [
    {"type": "demo-video", "required": true, "version": null, "check": "missing"}
  ],
  "verdict": {"verdict": "changes-requested", "gaps": "...", "version": {"id": "av_...", "number": 1}},
  "gaps": "...",
  "ticket": {"external_ref": "...", "url": "...", "title": "...", "body": "...",
             "filed_by": {"name": "Dana", "kind": "person"}, "filed_at": "...", "collection": "..."},
  "instruction": {"text": "...", "by": {"name": "dana"}, "at": "..."},
  "comments": [],
  "comments_omitted": 0,
  "answers": [],
  "notes": [
    {"kind": "request_changes", "stage_id": "st_...", "by": {"name": "dana"},
     "note": "Add the empty cart.", "artifact_version_id": "av_...", "at": "..."}
  ]
}
```

- `inputs` contains each input of the current stage with the version that the gate of
  the stage that made it approved, or a version a person added; `version` is null when
  there is none.
- `outputs` contains each output of the current stage with its newest version and its
  check: `passed`, `missing` or `not_checked`.
- `verdict` is the work item's newest verdict, or null for none. `gaps` is the stage's
  gaps.
- `ticket`, `instruction`, `comments`, `comments_omitted` and `answers` are the same as
  in Explore's input, within the same bound: at most 768 KiB encoded, with the oldest
  comments left out first and counted in `comments_omitted`. A test work item has no
  `ticket`.
- `notes` contains what people wrote on the work item, oldest first. `kind` is
  `request_changes`, a request for changes at the gate of the stage `stage_id`, which
  may point at one version in `artifact_version_id`; `move`, a move of the work item out
  of the stage `stage_id`; `escalation`, an escalation that a person resolved with a
  note; or `answer`, an answer to a run's questions, whose `stage_id` is null when the
  run of the question has no stage. `by` is the person, `note` the text and `at` the
  time it was written, or for an escalation the time it was resolved.
- For a work item that is in no stage, `stage` has only `id`, the stage of the run, or
  null, and `inputs` and `outputs` are empty.
- `run.workflow` and `run.round` are null for a run that has neither.

Errors: `410` `ticket_gone` when the ticket of a work item is no longer kept; `409`
`inputs_invalid` when a value of the ticket breaks Explore's input rules.

## GET artifacts

Returns `200` with the index:

```json
{
  "version": 1,
  "artifacts": [
    {
      "type": "demo-video",
      "name": "main",
      "stage_id": "st_...",
      "approved_version": "av_...",
      "newest_version": 2,
      "changed_after_approval": true,
      "versions": [
        {
          "id": "av_...",
          "number": 2,
          "writer": {"kind": "run", "run_id": "..."},
          "stage_id": "st_...",
          "note": null,
          "at": "2026-10-31T09:00:00Z",
          "files": [{"filename": "demo.mp4", "content_type": "video/mp4", "size": 1048576, "sha256": "..."}],
          "approvals": []
        }
      ]
    }
  ]
}
```

`approved_version` is the id of the newest version that a gate approved, or null for
none; `newest_version` is the number of the newest version. `changed_after_approval` is
true when the newest version is newer than the approved one and was made in a stage
other than the work item's stage. A version
written by a run has the run's id as the run's documents contain it; a version written
by a person has `"writer": {"kind": "person", "name": "dana"}`. An approval is
`{"by": {"name": "dana"}, "stage_id": "st_...", "at": "..."}`. The index contains no
file contents; `GET artifacts/<version_id>/files/<filename>` returns them.

## GET artifacts/<version_id>/files/<filename>

Returns `200` with the file's bytes, and these headers:

- `Content-Disposition: attachment; filename="<name>"; filename*=UTF-8''<name>`, where
  the first name has every character outside `A-Z a-z 0-9 . _ -` replaced by `_`;
- `X-Content-Type-Options: nosniff`;
- `Content-Type`: the file's content type, or `application/octet-stream` for a type
  with `html`, `xml`, `svg`, `javascript` or `ecmascript` in it, and for a type that is
  not a plain `type/subtype`.

`<filename>` is compared byte for byte with the names of the version's files, and is
never used as a path. A version of another work item, an unknown version id, a malformed
version id and an unknown filename all return `404` `not_found`.

## POST artifacts

The body, at most 32 MiB encoded, which is about 24 MiB of files once decoded. A larger
version cannot be pushed through the run API, whatever the type's size limit:

```json
{
  "type": "screenshot",
  "name": "checkout",
  "note": "After the fix.",
  "files": [
    {"filename": "checkout.png", "content_type": "image/png", "content_base64": "iVBORw0..."}
  ]
}
```

- `type`: the artifact type, 1 to 64 characters of `A-Z a-z 0-9 . _ -`, starting with a
  letter or a digit.
- `name`: optional, the same form, `main` by default. Several artifacts of one type
  have different names, such as screenshots of two screens.
- `note`: optional, at most 4000 code points, with no control character but a tab or a
  line break.
- `files`: 1 to 100 files. A `filename` is 1 to 255 bytes of UTF-8, not `.` or `..`,
  with no `/`, no `\` and no control character, and unique in the version. A
  `content_type` is `type/subtype`. `content_base64` is the content in standard base64
  with padding.

The version is stored for the run's work item, by the run, in the run's stage. Returns
`201`:

```json
{"version": 1, "artifact": {"type": "screenshot", "name": "checkout", "version": {"id": "av_...", "number": 3}}}
```

Checks, in order, after the checks of every request:

1. A body over 32 MiB, or over 64 KiB under a key id that is not an active gateway
   key's: `413` `payload_too_large`, unsigned, before the signature is checked.
2. A body that is not this object, or has a member it does not define: `400`
   `invalid_request`, with the first member that failed in `names`, such as
   `files[0].filename`.
3. A type the workspace does not have: `422` `unknown_type`.
4. A type the run's workflow may not write: `403` `type_not_writable`. A workflow may
   write the types in the `writes` list of its declaration in the stack, and always
   `verdict` and `questions`. A workflow whose declaration has no `writes` list, or that
   the harness no longer declares, may write any type the workspace has.
5. More files than the type's maximum: `422` `too_many_files`.
6. Files larger together than the type's size limit, which bounds all files of one
   version: `422` `too_large`.
7. A content that is not strict base64: `400` `invalid_request`.
8. Files that do not match the type's format: `422` `invalid_artifact`, with the file
   in `names`, such as `files[0]`, or `files` for a video type's version without a video
   file.

## POST verdict

The body, at most 64 KiB:

```json
{"verdict": "changes-requested", "gaps": "The demo skips the gift card step."}
```

- `verdict`: `passed`, `changes-requested` or `escalate`.
- `gaps`: optional text, at most 32000 code points, with no control character but a tab
  or a line break.

The verdict is stored as a new version of the artifact `verdict`, name `main`, with one
file, `verdict.json`, `{"verdict": ..., "gaps": ...}`, where `gaps` is null when the body
has none. A run of any workflow may give a verdict. Returns `201` with the version, as
`POST artifacts` does.

Checks: a body over 64 KiB is `413` `payload_too_large`; a body that is not this object
is `400` `invalid_request`.

## Errors

| Status | `error` | Other members | When |
|---|---|---|---|
| `400` | `invalid_request` | `names` | A body that is not the request's object, or a content that is not strict base64 |
| `401` | `unauthorized` | | The request does not verify; unsigned |
| `403` | `type_not_writable` | `type`, `message` | The run's workflow may not write the type |
| `404` | `not_found` | | An unknown run, a run of another gateway, an unknown version or file |
| `404` | (the error page) | | The instance does not have `workflow_model` |
| `409` | `run_ended` | `message` | A push or a verdict after the run ended |
| `409` | `inputs_invalid` | | A ticket value that breaks Explore's input rules |
| `410` | `ticket_gone` | | The work item's ticket is no longer kept |
| `413` | `payload_too_large` | | A body over its size |
| `422` | `unknown_type` | `type`, `message` | The workspace has no such artifact type |
| `422` | `too_many_files` | `type`, `limit`, `message` | More files than the type's maximum |
| `422` | `too_large` | `type`, `limit`, `message` | Files over the type's size limit together, in bytes |
| `422` | `invalid_artifact` | `names`, `message` | The files do not match the type's format |
| `503` | `unavailable` | | The request could not be completed; try again |

The messages:

- `run_ended`: "The run has ended, so it can no longer push artifacts or give a verdict."
- `unknown_type`: "Define the artifact type demo-findings in the workspace's Artifact
  types, then run the round again."
- `type_not_writable`: "Add the artifact type explainer to the writes list of the
  workflow capture-demo, or push a type that the workflow writes."
- `too_many_files`: "The artifact type screenshot takes at most 2 files in one version."
- `too_large`: "The files of one version of the artifact type demo-video take at most
  16777216 bytes together."
- `invalid_artifact`: "The files do not match the format of the artifact type."
