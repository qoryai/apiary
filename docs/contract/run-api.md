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

Every path is under `/v1/runs/<run_id>/`, where `<run_id>` is the run's id: `run_id` in
the signed `201` to the redemption of the run code, beside `run_key` and `documents`
(`run_answer` in Forager's enrolment contract,
`contracts/forager/v1/enrolment.schema.json`). Qory Apiary identifies the run by this
run id, under the gateway's access key: the gateway sends only the id of a run it
serves, and a request for a run the key does not serve gets `404` `not_found`.

| Method and path | What it returns |
|---|---|
| `GET work-item` | The work item as the run reads it (the work item snapshot) |
| `GET artifacts` | The work item's artifacts with their versions (the index) |
| `GET artifacts/<version_id>/files/<filename>` | One file of one version, as a download |
| `POST artifacts` | Stores a new version of an artifact; returns the version |
| `POST verdict` | Stores the run's verdict as a version of the `verdict` artifact |
| `GET resume/transcript` | The transcript of the paused run that the run continues, as a download |

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
   A push or a verdict checks the run of the queue again when it stores the version,
   under the lock of the work item that the end of a run also takes: a run whose run of
   the queue ended between the two checks is `409` `run_ended`, and no version is
   stored.
5. The checks listed with each request below.

An error is a JSON object with `error`, the code. Some errors also have `type`,
`limit`, `names` or `message`, as listed in the table of errors.

## GET work-item

Returns `200` with the work item snapshot:

```json
{
  "version": 1,
  "work_item": {"id": "wi_...", "number": 12, "url": "https://..."},
  "run": {"id": "<run_id>", "number": 57, "workflow": "capture-demo", "round": 2},
  "stage": {"id": "st_...", "name": "Build", "round": 2, "rounds": 3, "state": "running"},
  "inputs": [
    {"type": "acceptance-criteria", "required": true, "version": {"id": "av_...", "number": 2}}
  ],
  "outputs": [
    {"type": "demo-video", "required": true, "version": null, "check": "missing"}
  ],
  "verdict": {"verdict": "escalate",
              "points": [{"text": "...", "action": "answer", "question": "q4"}],
              "version": {"id": "av_...", "number": 1}},
  "gaps": "...",
  "ticket": {"external_ref": "...", "url": "...", "title": "...", "body": "...",
             "filed_by": {"name": "Dana", "kind": "person"}, "filed_at": "...", "collection": "..."},
  "instruction": {"text": "...", "by": {"name": "dana"}, "at": "..."},
  "comments": [],
  "comments_omitted": 0,
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
- `verdict` is the work item's newest verdict, or null for none. It can be from an earlier
  stage or an earlier run. At a run's end, the stage reads only a verdict that run pushed.
  `points` is its list of points, as the verdict's file has them, or null for a verdict
  with none.
- `gaps` is why the stage waits for a workflow, or the failed checks that started its
  round; null otherwise.
- `ticket`, `instruction`, `comments` and `comments_omitted` are the same as in
  Explore's input, within the same bound: at most 768 KiB encoded, with the oldest
  comments left out first and counted in `comments_omitted`. A test work item has no
  `ticket`.
- `notes` contains what people wrote on the work item and the gaps of failed checks,
  oldest first. `kind` is `request_changes`, a request for changes at the gate of the
  stage `stage_id`, which may point at one version in `artifact_version_id`; `move`, a
  move of the work item out of the stage `stage_id`; `escalation`, an escalation that a
  person resolved with a note; `answer`, an answer to a run's questions, a review comment
  on Explore's proposal or a reply to one, whose `stage_id` is null when the run it was
  given at has no stage; or `check`, the Exists
  checks of the stage `stage_id` that failed and started another round, with one line
  per missing output type in `note`. `by` is the person, null for `check`; `note` is the
  text; `at` is the time it was written, or for an escalation the time it was resolved.
- For a work item that is in no stage, `stage` has all five members: `id` is the stage
  id of the run, or null when the run has none, and `name`, `round`, `rounds` and
  `state` are null; `inputs` and `outputs` are empty lists.
- `run.number` is the run's number in its workspace, from 1, the number in the address of
  the run's page. A run takes its number when it is queued, before a machine takes it. No two runs of a workspace have the same number, and each workspace
  counts its runs apart from the others. A work item that moves into a workspace whose
  count is lower raises that count to the work item's highest number, so the workspace's
  numbers jump.
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
written by a run has `"writer": {"kind": "run", "run_id": "..."}`, with the `run_id` of
the answer to the redemption of the run code; a version written
by a person has `"writer": {"kind": "person", "name": "dana"}`. An approval is
`{"by": {"name": "dana"}, "stage_id": "st_...", "at": "..."}`. The index contains no
file contents; `GET artifacts/<version_id>/files/<filename>` returns them.

## GET artifacts/<version_id>/files/<filename>

Returns `200` with the file's bytes, and these headers:

- `Content-Disposition: attachment; filename="<name>"; filename*=UTF-8''<name>`, where
  the first name has every character outside `A-Z a-z 0-9 . _ -` replaced by `_`;
- `X-Content-Type-Options: nosniff`;
- `Content-Security-Policy`: the policy of every answer of Qory Apiary with the
  directive `sandbox` added, so a browser that opens the file runs no script of it and
  treats it as a page of no origin;
- `Content-Type`: the file's stored content type, with its `; charset=utf-8` where it
  has one, or `application/octet-stream` for a type with `html`, `xml`, `svg`,
  `javascript` or `ecmascript` in it, and for a type that is not a plain `type/subtype`.

The answer is signed as every answer is, except for the body digest in the answer
string: it is the stored `sha256` of the file, which Qory Apiary computed from the
file's bytes when it stored them and which the index returns. For a file whose stored
bytes are intact, that is the SHA-256 of the body sent, so the answer verifies as any
other. A stored file whose bytes no longer match its `sha256` fails the check.

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

- `type`: the artifact type, 1 to 64 bytes of lowercase letters and digits, in groups
  joined by single hyphens, such as `demo-video`.
- `name`: optional, the same form, `main` by default. Several artifacts of one type
  have different names, such as screenshots of two screens. `questions` and
  `review-comments` take only `main`: another name is `400` `invalid_request`, with
  `name` in `names`.
- `note`: optional, at most 4000 code points, with no control character but a tab or a
  line break, no format character but U+200C and U+200D, and no line or paragraph
  separator.
- `files`: 1 to 100 files. A `filename` is 1 to 255 bytes of UTF-8, not `.` or `..`,
  with no `/`, no `\`, no control or format character and no line or paragraph separator,
  and unique in the version. A `content_type` is `type/subtype`. The stored content type
  comes from the file's bytes, and the index returns it. `content_base64` is the content
  in standard base64 with padding.

The version is stored for the run's work item, by the run, in the run's stage; for a
run of Explore with no stage, one queued before the instance had `workflow_model`, in
the stage of the work item's process that runs Explore. Returns
`201`:

```json
{"version": 1, "artifact": {"type": "screenshot", "name": "checkout", "version": {"id": "av_...", "number": 3}}}
```

Checks, in order, after the checks of every request:

1. A body that is not this object, or has a member it does not define: `400`
   `invalid_request`, with the first member that failed in `names`, such as
   `files[0].filename`.
2. A type the workspace does not have, or a standard type it hides: `422` `unknown_type`.
3. More files than the type's maximum: `422` `too_many_files`.
4. Files larger together than the type's size limit, which bounds all files of one
   version: `422` `too_large`.
5. A content that is not strict base64: `400` `invalid_request`.
6. Files that do not match the type's format: `422` `invalid_artifact`, with the file
   in `names`, such as `files[0]`, or `files` for a video type's version without a video
   file and a `proposal` version without exactly one Markdown file. A version of the type
   `verdict` is checked against the type's JSON Schema, so its `verdict` is `passed`,
   `changes-requested` or `escalate`. A JSON file of a standard type, such as `questions`,
   `review-comments` or `verdict`, has each key once in each object: a key that comes
   twice is refused at the object's place, such as "at #/questions/0, the object has the
   key state twice", before the schema check. A question in `questions` has 0 to 4
   `options`, and at most one option has `recommended` true: a fifth option is refused
   as "at #/questions/0/options, value should have at most 4 items, got 5".

   A version of `proposal` has at most 10 files and 5 MiB (5242880 bytes) together:

   - exactly one Markdown file, whose filename ends in `.md`, of at most 262144 bytes;
   - at most one `sources.json`, of at most 1 MiB (1048576 bytes), one JSON document
     valid against qory's proposal sources format
     (`contracts/harness/v1/proposal-sources.schema.json`, copied to
     `priv/schemas/artifacts/proposal-sources.schema.json`). Qory Apiary checks the file
     against the schema and reads none of its members;
   - the rest PNG, JPEG, GIF, WebP or SVG images, each with the extension of its
     format: `.png`, `.jpg` or `.jpeg`, `.gif`, `.webp` or `.svg`. A file with another
     extension gets the proposal's format message; an image whose bytes are another
     format than its extension names, such as `cart.png` with the bytes of a GIF, gets
     "Replace cart.png with an image of the type its name ends in."

   An SVG of a proposal uses only the elements, attributes and structure below, so that
   it runs no script and loads nothing from outside the file: shown in an `<img>`, opened
   as an SVG, or opened as a page after a rename to `.html`, where an HTML parser reads
   no namespace. Names are compared as written, case included. Values and text are read
   with character references replaced. The message names the first part outside the
   list.

   - Elements, in the SVG namespace (`http://www.w3.org/2000/svg`), written with no
     prefix:
     - structure: `svg`, `g`, `defs`, `symbol`, `use`, `title`, `desc`
     - shapes: `rect`, `circle`, `ellipse`, `line`, `polyline`, `polygon`, `path`
     - text: `text`, `tspan`, `textPath`
     - link: `a`
     - paint: `linearGradient`, `radialGradient`, `stop`, `pattern`, `clipPath`, `mask`,
       `marker`
     - style: `style`
     - filters: `filter`, `feGaussianBlur`, `feOffset`, `feFlood`, `feComposite`,
       `feMerge`, `feMergeNode`, `feBlend`, `feColorMatrix`, `feDropShadow`
   - Attributes, on any of these elements, written with no prefix unless one is shown:
     - core: `id`, `class`, `style`, `lang`, `xml:lang`, `xml:space`, `role`,
       `aria-label`, `aria-hidden`
     - root: `version`, `viewBox`, `preserveAspectRatio`
     - geometry: `x`, `y`, `x1`, `y1`, `x2`, `y2`, `cx`, `cy`, `r`, `rx`, `ry`, `fx`,
       `fy`, `fr`, `width`, `height`, `d`, `points`, `pathLength`, `transform`,
       `transform-origin`
     - text: `dx`, `dy`, `rotate`, `textLength`, `lengthAdjust`, `startOffset`,
       `method`, `spacing`, `side`
     - presentation: `fill`, `fill-opacity`, `fill-rule`, `stroke`, `stroke-width`,
       `stroke-opacity`, `stroke-dasharray`, `stroke-dashoffset`, `stroke-linecap`,
       `stroke-linejoin`, `stroke-miterlimit`, `opacity`, `color`, `display`,
       `visibility`, `overflow`, `clip-path`, `clip-rule`, `mask`, `filter`,
       `marker-start`, `marker-mid`, `marker-end`, `stop-color`, `stop-opacity`,
       `flood-color`, `flood-opacity`, `font-family`, `font-size`, `font-weight`,
       `font-style`, `font-variant`, `text-anchor`, `dominant-baseline`,
       `alignment-baseline`, `baseline-shift`, `letter-spacing`, `word-spacing`,
       `text-decoration`, `writing-mode`, `white-space`, `vector-effect`,
       `shape-rendering`, `text-rendering`, `paint-order`, `mix-blend-mode`, `isolation`
     - paint servers and markers: `offset`, `gradientUnits`, `gradientTransform`,
       `spreadMethod`, `patternUnits`, `patternContentUnits`, `patternTransform`,
       `clipPathUnits`, `maskUnits`, `maskContentUnits`, `markerWidth`, `markerHeight`,
       `markerUnits`, `refX`, `refY`, `orient`
     - filters: `filterUnits`, `primitiveUnits`, `in`, `in2`, `result`, `stdDeviation`,
       `mode`, `operator`, `k1`, `k2`, `k3`, `k4`, `type`, `values`
     - links: `href` and `xlink:href`, only on `use`, `a`, `textPath`, `linearGradient`,
       `radialGradient` and `pattern`, and only to a place in the file: `#`, then an
       ASCII letter or `_`, then ASCII letters, digits, `_`, `-` or `.`, such as `#card`.

     Namespace declarations, `xmlns` and `xmlns:…`, may appear on any element; their
     values get the CSS checks below. Every other attribute is refused, such as
     `target`, `ping`, `src`, `cursor`, `xml:base` and every `on…` attribute.
   - Structure:
     - nothing but spaces, tabs, CRs and LFs after the end of the root `svg` element;
     - `title`, `desc` and `style` contain text only;
     - a CDATA section appears only inside `style`;
     - no comment's text starts with `>` or `->`, as in `<!-->` or `<!--->`;
     - no processing instruction, such as `<?xml-stylesheet ?>`. The XML declaration
       `<?xml version="1.0"?>` is not one.
   - CSS, in a `style` element and in every attribute value: no backslash, no
     `image-set(` (also `-webkit-image-set(`), `image(` or `src(`, any case, also with
     spaces before the `(`. The text of a `style` element is checked as one, joined
     across comments and CDATA sections.
   - In any text and attribute value: no `@import`, and a CSS `url(` only to an address
     that starts with `#`.

   An SVG is also at most 512 KiB (524288 bytes), else "Shrink checkout.svg to at most
   524288 bytes."; and UTF-8 text an XML parser reads to its end, with a root element
   `svg` written with no prefix or in the SVG namespace, else "Make checkout.svg a
   well-formed SVG file in UTF-8 with an svg root element." A root `svg` with no prefix
   outside the SVG namespace gets "Set xmlns="http://www.w3.org/2000/svg" on the svg root
   element of checkout.svg." A root with a prefix in the SVG namespace, such as `s:svg`,
   is refused by the strict check: "Remove the s:svg element from checkout.svg. …"
   Before the parse, a document type declaration
   (`<!DOCTYPE` or `<!ENTITY`, any case, outside a comment, a CDATA section and a
   processing instruction) is refused as "the DOCTYPE", and an element with more than 256
   attributes as "the attributes past the 256th on the rect element". An element that
   declares a prefix, or `xmlns`, twice is not well-formed XML and gets the "Make
   checkout.svg a well-formed SVG file …" message.
7. A version of `questions` or `review-comments` that changes what members wrote,
   compared with the newest version, or a version of `questions` that breaks one of the
   `decision` rules of this check: `422` `invalid_artifact`, with the file in `names`
   and the rule it breaks in `message`. In `questions`, the run keeps every `id` and the
   `asked` and `follows` of each question, keeps the questions of the newest version
   first, in the same order, and adds new questions after them, adds no `answer` and
   changes none, keeps each `history`, keeps `question`, `context` and `options` of each
   question that stays `answered`, each option's `recommended` included, moves the
   answer of a question it reopens unchanged to the end of its `history` with
   `reopened.run` set to its `run.number`, and adds each question with `asked.run` set
   to its `run.number` and with `follows`, if any, set to ids of questions before it in
   the version; an absent `follows` and an empty one are the same.

   The `decision` rules:

   - A version may add a question as `open`, without a `decision`, or as `decided`,
     with its `decision`.
   - A question that the newest version has does not change to `decided`: a run
     records a decision only on a question it adds.
   - A question that the version adds as `decided` has the title of one of its
     `options` in `decision.option`, and its `asked.run` in `decision.run`. The JSON
     Schema of the format cannot check this.
   - The run keeps the `decision` of each question that the newest version has,
     unchanged, also when it withdraws or reopens the question, and adds a `decision`
     to none of them.
   - The run keeps `question` and `options` of each question that has a `decision`, in
     every state, each option's `recommended` included, and its `context` while it
     stays `decided` or `answered`.

   In `review-comments`, the run keeps every review comment and every earlier reply
   unchanged, adds no review comment, and adds at most one reply to an open review
   comment, by `{"run": <run.number>}`, which it closes; a reply with the
   outcome `asked` has in `question` the id of a question of the newest version of
   `questions` stored when the run pushes `review-comments`, so the run pushes its
   questions first. Numbers compare by value, as the schemas' integers do: `4.0` is `4`.
   A version of `questions` or `review-comments` is stored with each number that is an
   integer in value written as an integer, so a later read of it has `4` where the push
   had `4.0`. Its size is measured as stored, after that change (`1e3` is stored as
   `1000`): a file that is then over the type's size limit is `422` `too_large`. A
   newest version of `questions` or `review-comments` whose file cannot be read, or
   whose newest `questions` a `review-comments` version is checked against cannot be
   read, is `503` `unavailable`, and no version is stored.

## POST verdict

The body, at most 64 KiB:

```json
{"verdict": "escalate",
 "points": [
   {"text": "The ticket does not say who may cancel a booking.",
    "action": "answer", "question": "q4"},
   {"text": "The checks script failed on the spec's links.", "action": "run_again"}
 ]}
```

- `verdict`: `passed`, `changes-requested` or `escalate`.
- `points`: what a person reads when the stage escalates, 1 to 20 points, required with
  `escalate` and absent otherwise. Each point has `text`, one plain sentence on one line
  of 1 to 500 characters that says what is wrong, with no action, and `action`: `answer`,
  with `question`, the id of an open question, or `run_again`, without `question`. The
  work item page adds the action's sentence: "Answer question 4." or "Run another
  round." The schema of the type `verdict`
  checks them (`priv/schemas/artifacts/verdict.schema.json`, a copy of qory's
  `contracts/harness/v1/verdict.schema.json`).

The verdict is stored as a new version of the artifact `verdict`, name `main`, with one
file, `verdict.json`, `{"verdict": ..., "points": ...}`, without `points` when the body
has none. A run of any workflow may push a verdict. For a run of Explore, only
`escalate` changes what happens: the stage escalates with the points. Explore treats
`passed` and `changes-requested` as no verdict. A run that leaves questions open and
gives `escalate` waits for answers first: its escalation is kept, and the answers run the
next round. Returns `201` with the version, as `POST artifacts` does.

A run of a workflow entry outside a loop must push a verdict. Make `qory run verdict
passed` the last step of the workflow, on a first run and on a rerun. A run that ends with
no verdict and no open question stops the stage: a member sees "The run stopped before its
verdict." with **Run another round** and, where an output has a version or no output is
required, **Accept as it is**. `changes-requested` outside a loop goes on to the next entry,
as `passed` does. In a loop, a run with no verdict runs the next workflow of the ring. A test
work item's run needs no verdict. Nor does a run of Explore whose take in has a proposal, or
that left open questions: Explore's result is its proposal or its questions. A run of
Explore that pushes `passed` or `changes-requested` goes on to the stage's checks.

Checks: a body over 64 KiB is `413` `payload_too_large`; a body with a member other than
`verdict` and `points`, or a `verdict` that is not one of the three, is `400`
`invalid_request`; points the schema refuses are `422` `invalid_artifact`. The question
of each `answer` point must be open in the newest `questions` of the work item's current
take in, so the run pushes its questions first; otherwise the verdict is `422`
`invalid_artifact`, with the message "Push the questions first, or point at an open
question in verdict.json: point 2 is about question q7, which is not open."

## GET resume/transcript

The session of a run that continues a paused run reads the paused run's transcript with
this request before its runtime starts, to resume the runtime's session. Unlike the other
requests, it belongs to the feature `observability`, the run endpoint's: without
`workflow_model` it is served all the same. The run's run configuration has `resume`,
with the paused run's id and the path of the transcript
([contract-assumptions.md](../contract-assumptions.md), A run that continues a paused
run).

The checks are 1 and 3 of the order of checks, then: a run that is no longer pending or
running, whose sending has ended, or whose run of the workspace's queue has ended, a run
with no `resume`, a paused run that is no longer the one the run continues, and a
transcript that is gone, has a gap in its offsets, is over 64 MiB or has 100,000 chunks
or more, are each `404`
`not_found`. Else the answer is `200`, `application/x-ndjson`, the paused run's chunks of
the transcript at the path of `resume`, in sequence order, sent in chunks and signed over
their SHA-256. A failure before the answer starts is `503` `unavailable`; one while the
chunks are sent ends the answer there. No byte of a transcript is logged.

## Errors

| Status | `error` | Other members | When |
|---|---|---|---|
| `400` | `invalid_request` | `names` | A body that is not the request's object, or a content that is not strict base64 |
| `401` | `unauthorized` | | The request does not verify; unsigned |
| `404` | `not_found` | | An unknown run, a run of another gateway, an unknown version or file; for `GET resume/transcript`, a run that ended, has no `resume`, or whose transcript cannot be served |
| `404` | (the error page) | | The instance does not have `workflow_model`, or for `GET resume/transcript`, `observability` |
| `409` | `run_ended` | `message` | A push or a verdict after the run ended, checked before the push and again when the version is stored |
| `409` | `inputs_invalid` | | A ticket value that breaks Explore's input rules |
| `410` | `ticket_gone` | | The work item's ticket is no longer kept |
| `413` | `payload_too_large` | | A body over its size |
| `422` | `unknown_type` | `type`, `message` | The workspace has no such artifact type, or hides the standard type |
| `422` | `too_many_files` | `type`, `limit`, `message` | More files than the type's maximum |
| `422` | `too_large` | `type`, `limit`, `message` | Files over the type's size limit together, in bytes; for `questions` and `review-comments`, as stored, with each number that is an integer in value written as an integer |
| `422` | `invalid_artifact` | `names`, `message` | A file does not match the type's format, a video version has no video, a `proposal` version has no Markdown file or more than one, a run's version of `questions` or `review-comments` breaks a rule of check 7, such as a change to what members wrote or to a `decision`, or a verdict's `answer` point is about a question that is not open |
| `503` | `unavailable` | | The request could not be completed, such as a newest version of `questions` or `review-comments` that cannot be read; try again |

The messages:

- `run_ended`: "The run has ended, so it can no longer push artifacts or give a verdict."
- `unknown_type`, for a custom name: "Define the artifact type demo-findings in the
  workspace's Artifact types, then run the round again."
- `unknown_type`, for a standard type the workspace hides: "Switch on the artifact type
  mockup in the workspace's Artifact types, then run the round again."
- `too_many_files`: "Push at most 10 files in one version of screenshot." ("1 file" for a
  limit of 1)
- `too_large`: "Shrink the files of one version of demo-video to at most 209715200 bytes
  together."
- `invalid_artifact`, by the check that failed:
  - "Fix checkout.png to match the format of screenshot: an image is a PNG, JPEG, GIF,
    WebP or SVG file." For a document type, the part after the colon is "a document is a
    Markdown file of UTF-8 text"; for a video type, "a file is an MP4 or WebM video, or a
    WebVTT file (.vtt)"; for a structured type, "the file is one JSON document".
  - "Fix notes.txt to match the format of explainer: the filename of a document ends in
    .md."
  - "Fix verdict.json to match the format of verdict: at #/verdict, value must be one of
    the enum values: "passed", "changes-requested" or "escalate"." For a file that fails
    a structured type's JSON Schema, the part after the colon is "at <path>, <error>.",
    with the JSON pointer of the first failing value and the text of the schema check.
  - "Push checkout.png again: Qory Apiary could not read it after it was received."
  - "Add an MP4 or WebM video to the version of demo-video: a WebVTT file goes with a
    video."
  - For a version of `proposal`:
    - "Fix notes.txt to match the format of proposal: a proposal is one Markdown file
      (.md) with PNG, JPEG, GIF, WebP or SVG images and an optional sources.json."
    - "Push one Markdown file (.md) in each version of proposal."
    - "Shrink proposal.md to at most 262144 bytes."
    - "Replace cart.png with an image of the type its name ends in."
    - "Shrink checkout.svg to at most 524288 bytes."
    - "Make checkout.svg a well-formed SVG file in UTF-8 with an svg root element."
    - "Set xmlns="http://www.w3.org/2000/svg" on the svg root element of checkout.svg."
    - "Remove the iframe element from checkout.svg. An SVG in a proposal uses only the
      elements and attributes the run API document lists, with no script, HTML or
      reference outside the file." The part after "Remove" names the first part
      refused, with element and attribute names as the file writes them: "everything
      after the end of the svg element", "the DOCTYPE", "the attributes past the 256th
      on the rect element", "the iframe element", "the s:rect element", "the HTML
      element h:div", "the ping attribute", "the href attribute", "the g element inside
      the desc element", "the CDATA section in the desc element", "the comment that
      starts with >", "the processing instruction foo", "a backslash in the fill
      attribute", "the url() in the style element", "the url() in the xmlns:a
      attribute", "the @import in the text of the desc element" or "the image-set() in
      the style attribute". A name past 64 characters is cut to 64 and "…".
  - For a version of `verdict` whose `answer` point is about a question that is not open:
    "Push the questions first, or point at an open question in verdict.json: point 2 is
    about question q7, which is not open."
    - "Shrink sources.json to at most 1048576 bytes."
    - "Make sources.json valid JSON. The file does not parse as JSON."
    - "Fix sources.json to match the format of proposal sources: at #, additional
      properties are not allowed but found property 'items'." The part after the colon
      is the JSON pointer of the first failing value and the text of the failed check: a
      schema check, or a check outside the schema such as a key that comes twice in an
      object ("the object has the key <key> twice", check 6).
  - For a version of `questions` or `review-comments` that changes what members wrote,
    one message per rule, such as "Leave each answer in questions.json as the newest
    version of questions has it: members write the answers." or "Close each review
    comment you reply to in review-comments.json."
  - For a version of `questions` that breaks one of the `decision` rules of check 7, the
    message of the rule, in the order of the rules:
    - A question added open with a decision: "Add each question in questions.json as
      open, with no decision, or as decided, with its decision."
    - A question of the newest version set to decided: "Record each decision in
      questions.json on a question you add, and set no question already in it to
      decided."
    - A decision whose option is not one of the question's option titles: "Set
      decision.option of each question in questions.json to the title of one of the
      question's options."
    - A decision whose run is not the question's asked.run: "Set decision.run of each
      question in questions.json to the question's asked.run: only the run that asked a
      question records a decision on it."
    - A decision changed, dropped or added later: "Leave the decision of each question in
      questions.json as the newest version of questions has it, and add none: only the
      run that adds a question records its decision."
    - The question or options of a question with a decision changed, or its context
      while it stays decided or answered: "Leave question and options of each question
      with a decision in questions.json as the newest version of questions has them, and
      its context while it stays decided or answered: to change them, withdraw the
      question and add a new one."
