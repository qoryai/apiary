# The run API

A run, an agent on a machine, uses the run API to read its work item and the work
item's artifacts, to push artifacts and its verdict, to report the commits it pushed, and,
in a stage whose workflows share one run, to get its next session. Each request is signed with the
access key of the gateway the run goes through; the run has no access key.

The run API is part of the feature `workflow_model`, which is off by default. On an
instance without the feature, a request that verifies gets `404` with the error page,
signed: the same body and type as a path the router does not know. A request without
a signature gets the `404` of a path the router does not know.

The code is in `lib/apiary_web/contract/run_api/`.

## The run's access level

The `access` of the run's documents is `read`, `write-no-push` or `write`
(`documents.schema.json` of the run contract). It sets what the run may do on its target,
not what it may do through the run API: a run of any level reads its work item and pushes
artifacts and a verdict. A run with `write-no-push` has a writable checkout and a work
credential with read access, so its credential cannot push to the target; only a
run with `write` has `submit`.

Qory Apiary computes the level once, when it claims the run. The level is the lower of two
levels, from lowest to highest `read`, `write-no-push` and `write`: the level the run's
workflow declares in the harness's stack (`workflows.<workflow>.access`), and the `access`
of the workflow's entry in the stage of `process.yaml`, which may be `read` or
`write-no-push`. An entry with no `access` leaves the stack's level; a workflow that sets
none declares `read`. A run of a stage whose version has no entry for its workflow has
`read`.

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
| `POST artifacts` | Stores a new version of an artifact, or a withdrawal of its name; returns the version |
| `POST verdict` | Stores the run's verdict as a version of the `verdict` artifact |
| `POST pushed-commits` | Adds the commits the run pushed to the run's list |
| `POST next-session` | Steps the stage on the end of a session of a shared run; returns the next session or the end |
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
4. For a POST: a run that has ended is `409` `run_ended`: a run that is not pending or
   running, unless it is lost after its attach and not yet lost for good; a run with its
   exit or whose events were pruned; and a run whose run of the workspace's queue has
   ended. A run found lost after its attach is lost for good once it has gone 600
   seconds without a heartbeat or is past its backstop; until then the gateway that
   attached it, restarted, attaches it again and pushes for it. A run a member cancelled
   is `409` `run_ended` too, from the commit of the cancel, whatever its state, with the
   message for a cancelled run, except for `POST pushed-commits`, which a cancel does not
   refuse (see that request). A run reads its work item after it ends; it writes nothing.
   A push or a verdict checks the run of the queue, and the cancel, again when it stores
   the version, under the lock of the work item that the end of a run and a cancel also
   take: a run whose run of the queue ended, or that a member cancelled, between the two
   checks is `409` `run_ended`, and no version is stored.
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
    {"id": "gd_...", "kind": "request_changes", "stage_id": "st_...", "by": {"name": "dana"},
     "note": "Add the empty cart.", "artifact_version_id": "av_...", "at": "..."}
  ],
  "pushed_commits": [
    {"system": "forge", "path": "acme/shop", "commit": "0123456789abcdef0123456789abcdef01234567",
     "run_id": "<run_id>", "cancelled": false, "at": "2026-11-17T09:00:00Z"}
  ]
}
```

- `inputs` contains each input of the current stage with the version that the gate of
  the stage that made it approved, or a version a person added; `version` is null when
  there is none. A person's change to an approved output comes first. A change is a
  version that has a `decision` (`POST artifacts`) or that a person uploaded, in any
  stage, that no approval lists, and whose number is higher than that of every version
  of its artifact that an approval lists. A withdrawal, a version of a withdrawn name and
  a version by a run that a member cancelled are never a change. A person's version of the
  type in `submit.type` of the work item's process version is not a change: no approval
  lists it, `outputs` leaves it out, and runs read the run's version. Each name's change is
  its highest-numbered one, and the input is the newest of those by time. Every later run
  reads that version in place of the approved one, until an approval lists it. Where an
  approval lists several versions of one name, the input is the highest-numbered one.
  Where it lists several names of one type, the input is the name whose listed version
  is newest. A version that a person's approval listed is the approved version for every
  run after that approval, in any stage, also after a move back to a stage at or before
  that approval.
  `questions` and `review-comments` are never a change.
  After a person moves the work item to an earlier stage (a move back, an
  escalation's move back or a switch of track), `inputs` ends with one more entry for each output of each stage
  that the work item left that way and that comes after its current stage:
  `{"type": "demo-video", "required": false, "version": {"id": "av_...", "number": 3},
  "from": "move"}`. `version` is the newest version of that type made in the left stage
  from the time the work item last entered it to the time it left, leaving out
  withdrawals, withdrawn names and versions by a run a member cancelled; an output with no
  such version has no entry. The entries last until the left stage's gate passes again (an
  approval of that stage, by a person or automatic) or a later move takes the work item to
  a stage after it, and only for the take in of the move. A stage that the work item left
  twice counts by its newer move. An entry is left out when an input above it already has
  that version. The key `from` is present on these entries, and no approval lists such
  a version, unless a person made it: that is a change.
- After a run of a stage returns the work item to an earlier stage (the `return` key of a
  workflow entry), `inputs` ends with the newest `verdict` and then the newest
  `verification` made in the stage that returned it, each as
  `{"type": "verdict", "required": false, "version": {"id": "av_...", "number": 2},
  "from": "return"}`. A type with no such version has no entry, and an entry is left out
  when an input above it already has that version. The entries last until the gate of the
  stage that the work item returned to passes again (an approval of that stage) or the
  work item leaves that stage by a move, after the return; a Request changes at its gate
  and a decision in another stage end nothing. A later return lists the newer versions. No
  approval lists them, and `notes` does not.
- `outputs` contains each output of the current stage with the version its gate shows
  and its check: `passed`, `missing` or `not_checked`. For the type in `submit.type`,
  only a run's version passes the check. The version is the newest one
  made in the stage, or a higher-numbered version of that artifact that a person's
  approval lists or that is a change, which every later run reads, also after a move
  back to the stage.
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
  stage `stage_id`, whose `note` is never empty, and which may point at one version in
  `artifact_version_id`; `move`, a
  move of the work item out of the stage `stage_id`, not one that resolves an escalation
  (a move back or a switch of track), which the escalation's entry stands for;
  `escalation`, an escalation that a person resolved with a note; `answer`, an answer to a run's questions, a review comment
  on Explore's proposal or a reply to one, whose `stage_id` is null when the run it was
  given at has no stage; or `check`, the Exists
  checks of the stage `stage_id` that failed and started another round, with one line
  per missing output type in `note`. `by` is the person, null for `check`; `note` is the
  text; `at` is the time it was written, or for an escalation the time it was resolved.
  `id` is the note's id: `gd_` and 16 characters for a request for changes or a move, a
  decision at a gate; `es_` and 16 characters for an escalation; null for `answer` and
  `check`. A run sends it as `decision` in `POST artifacts`, for a version that the note
  asked for.
  `notes` contains only open notes. A note closes once the stage `stage_id` has an
  approval after `at`, and a `move` once the stage it moved to has one: a member's, or
  the automatic approval of a gate `none`. An `answer` whose `stage_id` is null stays
  open. A move that resolves an open escalation is one `move` note, with no
  `escalation` note. Two records are missing from before Qory Apiary kept them: a
  `move` written then has no stage it moved to, so it stays open; and a gate `none`
  that passed on then recorded no approval, so the notes of that stage stay open until
  the stage passes its gate again.
- `pushed_commits` contains the commits that the earlier runs of the work item reported with
  `POST pushed-commits`, from every stage, and none that the requesting run reported. An earlier
  run is a run of the work item with a lower `run.number`. Entries are ordered by the run's
  number, then by the order in which Qory Apiary recorded the run's commits: entries of
  one run are in the order Apiary recorded them, and two posts in the same second keep that
  order. `run_id` is the id of the run that reported the commit, as in `writer` of an
  artifact version. `cancelled` is true when a member cancelled that run, and false for a
  run that ended at its time limit, was released or lost its machine. `cancelled` is read
  when the work item is read, so a cancel after the report marks the run's earlier commits
  too. `at` is when Qory Apiary recorded the commit. The list is `[]`, never null, when
  there is none.
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
          "cancelled": false,
          "withdrawn": false,
          "stage_id": "st_...",
          "note": null,
          "decision": null,
          "decision_at": null,
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
none; `newest_version` is the number of the newest version, leaving out versions by a
run a member cancelled, and null when a run a member cancelled wrote every version.
`changed_after_approval` is true when that newest version is
newer than the approved one and was made in a stage other than the work item's stage.
For the type in `submit.type` of the work item's process version, `changed_after_approval`
compares the newest version a run wrote in place of `newest_version`, as a person's
version of that type is not a change.
A version
written by a run has `"writer": {"kind": "run", "run_id": "..."}`, with the `run_id` of
the answer to the redemption of the run code; a version written
by a person has `"writer": {"kind": "person", "name": "dana"}`. `cancelled` is true when
a member cancelled the run that wrote the version, and false for a version of any other
run or of a person. `withdrawn` is true for a withdrawal, a version a run stored with no
files (`files` is `[]`), and false for every other version. A name is withdrawn when its
newest version, leaving out versions by a run a member cancelled, is a withdrawal. The
index lists a withdrawn name with its versions, and the stage's outputs and inputs in
`GET work-item` and the work item's pages leave it out. A run cannot withdraw `verdict`,
so the newest verdict in `GET work-item` is never a withdrawal. An approval is
`{"by": {"name": "dana"}, "automatic": false, "stage_id": "st_...", "at": "..."}`. A
gate `none` records an approval of the stage's newest versions, leaving out withdrawals
and versions by a run a member cancelled, when the stage passes it:
`{"by": null, "automatic": true, ...}`. When a member accepted the escalation that ended
such a stage, the approval has the member in `by` and `automatic` false. `decision` is
the id of the person's note that asked for the version (`POST artifacts`), and
`decision_at` the time of that note, as `at` of the note in `GET work-item`; both are
null for a version with none. A gate `none` lists no version that has a `decision`.
The next approval by a person at a gate lists the newest version of each name of each
output type made in the stage, or a higher-numbered version of that name that a person's
approval lists or that is a change, and beside them the change of each type that
`inputs` in `GET work-item` reads. The index
contains no file contents; `GET artifacts/<version_id>/files/<filename>` returns them.

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
  `name` in `names`. `acceptance-criteria` takes only `main` too, because a work item has
  one set of acceptance criteria: another name is `422` `invalid_artifact`, with `name` in
  `names`, after the base64 check and before the format check.
- `note`: optional, at most 4000 code points, with no control character but a tab or a
  line break, no format character but U+200C and U+200D, and no line or paragraph
  separator.
- `decision`: optional, text or null. The `id` of the person's note on the work item that
  asked for this version, from `notes` in `GET work-item`, such as `gd_01jc4t9…`: a
  request for changes, a move or an escalation. Later runs read a version that has a
  `decision` in place of the approved one, and the next approval by a person lists it
  (`inputs` in `GET work-item`). A push with none is stored as before.
- `withdraw`: optional, `true`, `false` or null, `false` by default. With `true`, the push
  is a withdrawal (see [A withdrawal](#a-withdrawal)), and `files` is absent, null or
  `[]`.
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
   as "at #/questions/0/options, value should have at most 4 items, got 5". Each
   question has an `about`, what it is about: `{"work_item": true}` for the work item
   itself, or one output of the work item, `{"type": …, "name": …}`, with an `item`, 1 to
   32 characters on one line, where the question is about one entry of that output. For
   the type `acceptance-criteria`, the `item` is a criterion id: `ac-` and a number from
   1 to 9999 with no leading zero, such as `ac-3`; another value, such as `AC-3`, is
   refused as "at #/questions/0/about/item, value does not conform to pattern
   /^ac-[1-9][0-9]{0,3}\z/". Qory Apiary stores `about` as the run pushed
   it. An option of a question whose `about` has an `item` may have a `proposal`, the
   new wording of that entry that the run proposes, 1 to 2,000 characters with line
   breaks allowed; the page shows it in a field that a member may edit before answering.
   For a `proposal` on a question whose `about` has no `item`, the push fails with `422`
   `invalid_artifact`. A version of `acceptance-criteria` or `verification` is one JSON
   file, checked against qory's acceptance criteria or verification format
   (`contracts/harness/v1/acceptance-criteria.schema.json` and
   `verification.schema.json`, copied to `priv/schemas/artifacts/`); Qory Apiary reads
   no Markdown of either type. A criterion whose id an earlier criterion has is refused
   at its id, the fix first: "at #/criteria/2/id, give criterion 3 an id that no earlier
   criterion has: ac-1 is taken".

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

   A run's version of `mockup` with a file named `screens.json` is a mockup of pages:
   `screens.json` and one HTML page per screen, and no other file. A version of `mockup`
   without `screens.json` is a mockup of images, checked and shown as before.

   - `screens.json` is at most 64 KiB (65536 bytes), one JSON document valid against
     Qory Apiary's schema of the mockup format,
     `priv/schemas/artifacts/mockup.schema.json`: 1 to 9 screens, each with an `id`, a
     `title`, a `file` that is the id and `.html`, its `criteria` and its `links`.
     Beside the schema, Qory Apiary checks that the ids differ, that `start` and each
     link's `to` are ids of screens, and that every screen can be reached from `start`
     through links. A refusal is "Fix screens.json to match the format of mockup: at
     <path>, <error>.", such as "at #/start, use the id of a screen, not `gone`". A
     screen's `title` with a space at its start or end, or two spaces in a row, is
     refused at that title: it matches no page's `<title>`. A `title` or a link's
     `label` that is empty, longer than 200 characters or has a control character gets
     its fix, such as "Shorten the title of screen `home` in `screens.json` to at most
     200 characters: it has 201.", at `files[<n>]`.
   - Each page is at most 1 MiB (1048576 bytes) of UTF-8 with no byte order mark, has at
     most 10,000 start tags and at most 256 attributes on one tag, and follows Qory
     Apiary's page rules for a mockup: it runs no script, loads nothing from outside the
     version but base64 `data:` images and fonts, sends no form, has exactly one
     `<title>` equal to the screen's `title`, and links with `<a href="<id>.html">`
     exactly to the screens of its `links`. The page is read as a browser reads it,
     by the HTML5 algorithm. In the `<title>`, each run of ASCII white space is one
     space and the ends are trimmed; a no-break space stays.
   - A refusal's message has the file and the fix, such as "Remove the `<script>`
     element from `home.html` (screen `home`): a mockup page runs no script." at
     `files[1]`, or "Add `home.html` to the version: it is the page of screen `home` in
     `screens.json`." at `files`.
7. A version of `questions` or `review-comments` that changes what members wrote,
   compared with the newest version, or a version of `questions` that breaks one of the
   `decision` rules of this check: `422` `invalid_artifact`, with the file in `names`
   and the rule it breaks in `message`. In `questions`, the run keeps every `id` and the
   `asked` and `follows` of each question, keeps the questions of the newest version
   first, in the same order, and adds new questions after them, adds no `answer` and
   changes none, keeps each `history`, keeps `question`, `context`, `options` and
   `about` of each question that stays `answered`, set or absent, each option's
   `recommended` included, moves the answer of a question it reopens unchanged to the
   end of its `history` with `reopened.run` set to its `run.number`, and adds each
   question with `asked.run` set to its `run.number` and with `follows`, if any, set to
   ids of questions before it in the version; an absent `follows` and an empty one are
   the same. The run may change the `about` of an open question.

   The `about` of each question that the version adds, or whose `about` it changes, is
   the work item, or an output of the work item: an artifact of that `type` and `name`
   whose newest version is not a withdrawal. Its `item`, for the type
   `acceptance-criteria`, is the id of a criterion in any version of that artifact, a
   criterion that a later version removes or leaves out included. Qory Apiary checks no
   `item` of another type. A question that keeps its
   `about` is not checked again.

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
     every state, each option's `recommended` included, and its `context` and
     `about` while it stays `decided` or `answered`.

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
8. A `decision` that is not the `id` of a person's note on the run's work item, such as
   an approval's id, another work item's note or an unknown id: `422`
   `unknown_decision`. This check runs under the work item's lock after the rules of
   check 7 and before the size of `questions` or `review-comments` as stored.

### A withdrawal

A run withdraws a name it no longer makes, such as a demo scenario that a rework
removed, with a push of `"withdraw": true` and no files:

```json
{"type": "demo-script", "name": "scenario-2", "withdraw": true, "note": "Shape removed scenario-2."}
```

Qory Apiary stores a version of `demo-script` `scenario-2` with no files and
`withdrawn` true, by the run, in the run's stage, with the note and the `decision`, if
the push has one, and returns `201` with the version, as a push does. The index lists
the withdrawal with its `decision` and `decision_at`; a withdrawal is never a change
that `inputs` reads. Gates, stage inputs and the work item's pages leave out a
withdrawn name. A stage done whose last approval covered a version of that name is at its
gate again. A later push of files is a new version, and lists the name again.

A run cannot withdraw `questions`, `review-comments`, `verdict` or `proposal`: Qory
Apiary reads them itself, and a run pushes a new version of them instead. It cannot
withdraw a name of a type whose entry in the template's `artifact_types` sets
`withdrawable: false`, a standard type with an entry of `name` and `withdrawable` alone or
a custom type (`withdrawable` is true when the entry has none). It cannot withdraw a name
of the type in `submit.type` of its process version or of its work item's process
version: Qory Apiary reads the newest version of that type as the run's submission.
Versions stored earlier stay listed. It cannot withdraw a name whose newest version a member approved at a
gate, and pushes a new version instead. An approval that the runner recorded for a gate
`none` does not count, and neither does an approval of an older version.

Checks, in order, after the checks of every request:

1. A body that is not the push's object, as for a push: `400` `invalid_request`.
2. A type the workspace does not have, or a standard type it hides: `422`
   `unknown_type`.
3. `questions`, `review-comments`, `verdict` or `proposal`, a type with
   `withdrawable: false`, or the type in `submit.type` of the run's process version or of
   the work item's: `422` `type_not_withdrawable`.
4. A `files` list with one file or more: `422` `withdrawal_with_files`.
5. Under the work item's lock, with the check of a run that ended, by the newest version
   of the name, leaving out versions by a run a member cancelled: one that a member
   approved at a gate, `422` `type_not_withdrawable`, checked before the rest; none, `409`
   `no_version`; a withdrawal, `409` `already_withdrawn`; a version a person uploaded,
   `409` `person_version`. A run withdraws only a name whose newest version a run wrote.
6. A `decision`, as check 8 of a push: `422` `unknown_decision`.

No version is stored for a refused withdrawal.

## The submission the pages list

Qory Apiary lists the versions of the type in `submit.type` of the work item's process
version on the work item's pages (the Submissions list and a run's Submission block). It
reads these members of a version's JSON file, at most 1 MiB, and leaves out any value that
is not of the form below. A stored text is cut to its first 200 characters.

- `ref`: the branch, a string.
- `repositories`: at most 20 objects, each with `system`, `path`, `commit` (the head, 40 or
  64 lowercase hex characters) and, optionally:
  - `commit_url`: an `https` address of the head commit, at most 2048 characters.
  - `base`: `{commit, commit_url}`, the commit the run started at.
  - `commits`: `[{commit, step, commit_url}]`, the run's commits in the order it made
    them, the last the head. `step` is `deliverable:<id>`, the id of a row in the Id column
    of the build plan's Deliverables table, or `fix:<finding id>`; an entry whose `commit`
    is not a full hex id is left out. The head is marked on the last entry whose `commit`
    is the repository's `commit`; where no entry is, none is marked and the list is shown as
    read. A page lists at most 100 entries of a repository: the first 100, or the first 99
    and the head where the head is a later entry; the count has every entry.
  - `draft`: `{number, url, title}` for a draft sent to the destination, or `{none: <reason>}`.

A link that is not `https` is not shown as a link. The Base line says "the head of Run <n>" ("the result of Run <n>" outside a software workspace)
where an earlier submission of the work item, among the newest 50 versions, ends at the base
commit in the same repository. Where a version that is not listed (older than those, or
written by a run a member cancelled) may end at it, the line shows the commit alone.

The text of a change comes from the Change column of the first 200 rows of the build plan
(`build-plan`, the file `build-plan.md`) that was newest when the version was stored. A plan
over 256 KiB gives no change texts, and a stored submission over 1 MiB lists no repository.

## POST verdict

The body, at most 64 KiB:

```json
{"verdict": "escalate",
 "points": [
   {"text": "The ticket does not say who may cancel a booking.",
    "action": "answer", "question": "q4"},
   {"text": "The checks script failed on the spec's links.", "action": "run_again"}
 ],
 "track": {"id": "small-change", "reason": "The change touches one file."}}
```

- `verdict`: `passed`, `changes-requested` or `escalate`.
- `points`: what is wrong or missing, 1 to 20 points. With `escalate`, points are
  required, and a person reads them when the stage escalates. With `changes-requested`,
  points are optional, and each point's `action` is `run_again`; the verdict's page shows
  them as it shows every other member of the file. If a `changes-requested` verdict with
  points ends the last round of a loop, the stage escalates at its round limit with one
  point. Its text is "3 of 3 rounds ran, and 2 review findings are still open." followed
  by the `text` of each point, and its fix is "Read the 2 open findings, then pick Accept
  as it is or Run another round." With no points, the text is "3 of 3 rounds ran." The
  stage runner writes this point, and the limit of one sentence and 500 characters below
  does not apply to it: with points, its text is more than one sentence and can be
  longer than 500 characters. With `passed`, a verdict has none.
  Each point has `text`, one plain sentence on one line of 1 to 500 characters that
  states what is wrong, with no action, and `action`: `answer`, with `question`, the id of
  an open question, or `run_again`, without `question`. A `run_again` point may also have
  `fix`, one plain sentence on one line of 1 to 500 characters that states what a person
  does about it; an `answer` point has no `fix`. For an escalation, the work item page
  adds the action's sentence: "Answer question 4." or "Run another round." A point's
  `fix` takes the place of "Run another round." The page shows `text` and `fix` as plain
  text. The schema of the type `verdict` checks them
  (`priv/schemas/artifacts/verdict.schema.json`).
  That file is the source of the schema, and qory keeps a byte copy of it at
  `contracts/harness/v1/verdict.schema.json`.
- `track`: optional, for any verdict. The track the run proposes for the work item:
  `id`, the id of a track that the gate of the run's stage offers, and `reason`, why, in
  one sentence on one line of 1 to 300 characters. Both are required when `track` is
  present. When a person approves the gate with no track chosen, the approval records
  this track, if the gate offers it. A verdict with no `track` proposes none.
- `full_suite`: optional, for any verdict. The result of the run of the full test suite, as
  the run reports it. `state` is required and is `passed`, `failed` or `not_run`.
  - With `passed` or `failed`, `minutes` is required: how long the run took, a number from 0
    to 100,000. `passed`, `failed` and `skipped` are the counts of tests, each a whole number
    from 0 to 1,000,000,000, either all three or none of them: one or two of the three is
    refused. `reason` is not allowed.
  - With `not_run`, `reason` is required: why the suite did not run, one sentence on one
    line of 1 to 300 characters, as `track.reason` is. The counts and `minutes` are not
    allowed.
  - Any other member, a state other than the three, and a value of another type are
    refused. A verdict with no `full_suite` reports no result.

The verdict is stored as a new version of the artifact `verdict`, name `main`, with one
file, `verdict.json`, `{"verdict": ..., "points": ..., "track": ..., "full_suite": ...}`,
without `points`, `track` or `full_suite` when the body has none. `full_suite` is stored as
the run sent it. A body with `"track": null` has none: it is stored
without `track`, as `"points": null` is stored without `points`, and `"full_suite": null`
is stored without `full_suite`. A run of any workflow may
push a verdict. A `changes-requested` verdict moves the stage in the same way with points
as without them. For a run of Explore, only
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
`verdict`, `points`, `track` and `full_suite`, or a `verdict` that is not one of the
three, is `400` `invalid_request`; points, a track or a `full_suite` the schema refuses are
`422` `invalid_artifact`. A
`track.id` that the gate of the run's stage does not offer is `422` `invalid_artifact`
with `names` `["track"]` and the message in "The messages", for a push of the artifact
`verdict` too. The question
of each `answer` point must be open in the newest `questions` of the work item's current
take in, so the run pushes its questions first; otherwise the verdict is `422`
`invalid_artifact`, with the message "Push the questions first, or point at an open
question in verdict.json: point 2 is about question q7, which is not open."

## POST pushed-commits

A run reports the commits it pushed to its targets, after each push, so that the next run
of the work item can continue from them. The body, at most 64 KiB:

```json
{"repositories": [
  {"system": "forge", "path": "acme/shop", "commit": "0123456789abcdef0123456789abcdef01234567"}
]}
```

- `repositories`: 1 to 64 objects, each with exactly `system`, `path` and `commit`. Send
  every repository the push moved. `system` and `path` are the place the commit went to, as
  a target label (1 to 256 bytes, no control character). `commit` is the full commit id:
  40 or 64 lowercase hexadecimal characters. Qory Apiary reads no git and checks only that
  form; whether a commit descends from another is the run's check.
- Qory Apiary appends one entry for each commit and place, in the order of `repositories`,
  to the run's list. A commit that the run reported before for the same `system` and
  `path`, or twice in one body, is stored once and takes no position: the run may send
  a report again. Entries of one run are in the order Apiary recorded them, and two posts
  in the same second keep that order.
- Returns `204`, signed, with no body.
- The report is stored under the lock of the work item that a push, a verdict, the end of a
  run and a cancel also take. A cancel that a member requested does not refuse it: the
  run goes on until its exit arrives, and what it pushed before then is on the forge. Such
  a commit is listed with `cancelled` true. A report is refused with `409` `run_ended` only
  once the run's end is recorded.
- The run API lists the commits to later runs in `pushed_commits` of `GET work-item`.

Checks, after checks 1 to 4 of the order of checks: a run that has not `write` access is
`409` `not_writable`, before the body is read; a body over 64 KiB is `413`
`payload_too_large`, as for a verdict; a body that is not an object with `repositories`,
has more than 64 repositories, or has a member other than the ones above, or a `commit`
that is not a full commit id, is `400` `invalid_request`, with the first member that failed
in `names`, such as `repositories[1].commit`; `body` for a body that is not a JSON object,
and `repositories` for a list that is empty, over 64 or not a list.

## POST next-session

A run of a stage with `shared_run: true` runs the stage's workflows one after the other as
sessions of one run. After each session that did not pause, qory sends this request from
the run's host, never from a container, over the gateway's link; the gateway sends it here
signed with its access key, as every request of the run API. The run's documents have
`shared_run` true. The body, at most 4 KiB, is `next-session-request.schema.json` of the
run contract:

```json
{"session": 1, "state": "succeeded", "reason": null}
```

- `session`: Forager's number of the session that ended, from 1.
- `state`: `succeeded`, `failed` or `cancelled`, the state of its
  `dev.qory.session.exited`.
- `reason`: the reason of that event, a code of a lower-case letter, then lower-case
  letters, digits and `_`, up to 64 characters, or null for none. A `cancelled` session
  has a reason; `timeout` and `interrupted` are for a `cancelled` session only, and
  `gateway_lost` for a `failed` session only.

Qory Apiary steps the stage on the session's end as on the end of a run of a stage that
does not share its run: the open questions of the run's take in, else the newest
`verdict` version the run stored after the previous step, else, for `failed` or
`cancelled`, a run that stopped without a result. Then it returns `200`, signed, with
`Content-Type: application/json` and one of two bodies, `next-session-answer.schema.json`
of the run contract. A next session of the same stage:

```json
{"next": "session", "session": 2, "workflow": "write-acceptance-checks",
 "time_limit_minutes": 180, "full_suite": false, "inputs": {"version": 1, "...": "..."}}
```

- `session`: Qory Apiary's number of the session in the run, from 1; the claim's session is
  1. It is not Forager's number.
- `workflow`, `time_limit_minutes` and `full_suite`: the entry's, as the claim kept them,
  so a time limit saved after the claim changes nothing for the run.
- `inputs`: the input of the session, in the shape of the documents' `inputs`.
- `model_choice` and `model_credential` are left out: every session uses the run's model
  choice and key.

Or the end of the run, where the stage runs no further workflow in this run: an
escalation, open questions, the gate, or the next stage, whose run is queued as any run:

```json
{"next": "end"}
```

- A body is at most 1 MiB, the largest `200` the gateway passes back. `inputs` takes what
  the rest of the body leaves, with the oldest comments of the ticket left out first and
  counted in `comments_omitted`.
- A second request for the same session returns the same body, byte for byte, and steps
  nothing, whatever the newer verdicts: qory may send it again after a `5xx` or a
  transport failure. A request for an older session than the newest one the run reported
  is `409` `session_mismatch`.
- The step and the record of the session are stored in one transaction, under the lock of
  the work item that a push, a verdict, the end of a run and a cancel also take. An error
  writes nothing, except the end of the run for inputs that cannot be formed.

Checks, after checks 1 to 4 of the order of checks: a body over 4 KiB is `413`
`payload_too_large`; a body outside the request's schema is `400` `invalid_request`, with
the first member that failed in `names`, `body` for a body that is not a JSON object; then:

- a run of a stage without `shared_run`, a run of Explore, and a run that no claim of such
  a stage registered are `404` `not_found`;
- a run that the stage no longer runs, or whose last step returned `end`, is `409`
  `run_ended`;
- a store that cannot read the run's newest verdict or questions is `503` `unavailable`;
- a ticket that is no longer kept, or inputs that break the rules of Explore's input or do
  not fit the body's 1 MiB with every comment left out, end the run, as a claim ends a run
  it cannot form, with the cause `ticket_gone` or `inputs_invalid` and the outcome `error`,
  and are `409` `run_ended`. The stage escalates `run_stopped`.

Qory Apiary never returns `410` to this request, as the gateway turns a `410` into a `502`.

## GET resume/transcript

The session of a run that continues a paused run reads the paused run's transcript with
this request before its runtime starts, to resume the runtime's session. Unlike the other
requests, it belongs to the feature `observability`, the run endpoint's: without
`workflow_model` it is served all the same. The run's run configuration has `resume`,
with the paused run's id, the path of the transcript, and `runs`, every paused run the
run continues, oldest first
([contract-assumptions.md](../contract-assumptions.md), A run that continues a paused
run).

The checks are 1 and 3 of the order of checks, then: a run that has ended, as in check
4, a run with no `resume`, a paused run that is no longer the one the run continues, and a
transcript that is gone, has a gap in its offsets, is over 64 MiB or has 100,000 chunks
or more, are each `404`
`not_found`. Else the answer is `200`, `application/x-ndjson`, the paused run's chunks of
the transcript at the path of `resume`, in sequence order, sent in chunks and signed over
their SHA-256. A failure before the answer starts is `503` `unavailable`; one while the
chunks are sent ends the answer there. No byte of a transcript is logged.

## Errors

| Status | `error` | Other members | When |
|---|---|---|---|
| `400` | `invalid_request` | `names`, and `message` for a report of pushed commits and a next-session request | A body that is not the request's object, a report of pushed commits over its limits or with a commit that is not a full commit id, a next-session request outside its schema, or a content that is not strict base64 |
| `401` | `unauthorized` | | The request does not verify; unsigned |
| `404` | `not_found` | | An unknown run, a run of another gateway, an unknown version or file; for `GET resume/transcript`, a run that ended, has no `resume`, or whose transcript cannot be served; for `POST next-session`, a run of a stage without `shared_run` |
| `404` | (the error page) | | The instance does not have `workflow_model`, or for `GET resume/transcript`, `observability` |
| `409` | `run_ended` | `message` | A push or a verdict after the run ended or a member cancelled it, checked before the push and again when the version is stored; a report of pushed commits after the run ended (a cancel does not refuse it), checked before and again under the work item's lock |
| `409` | `run_ended` | `message` | A next-session request after the run ended or a member cancelled it, after the stage stopped running the run, or for inputs that ended the run |
| `409` | `session_mismatch` | `message` | A next-session request for an older session than the newest one the run reported |
| `409` | `not_writable` | `message` | A report of pushed commits from a run whose access is not `write` |
| `409` | `inputs_invalid` | | A ticket value that breaks Explore's input rules |
| `409` | `no_version` | `type`, `message` | A withdrawal of a name that has no version outside cancelled runs |
| `409` | `already_withdrawn` | `type`, `message` | A withdrawal of a name whose newest version is a withdrawal |
| `409` | `person_version` | `type`, `message` | A withdrawal of a name whose newest version a person uploaded |
| `410` | `ticket_gone` | | The work item's ticket is no longer kept |
| `413` | `payload_too_large` | | A body over its size |
| `422` | `unknown_type` | `type`, `message` | The workspace has no such artifact type, or hides the standard type |
| `422` | `too_many_files` | `type`, `limit`, `message` | More files than the type's maximum |
| `422` | `too_large` | `type`, `limit`, `message` | Files over the type's size limit together, in bytes; for `questions` and `review-comments`, as stored, with each number that is an integer in value written as an integer |
| `422` | `type_not_withdrawable` | `type`, `message` | A withdrawal of `questions`, `review-comments`, `verdict` or `proposal`, of a name of a type with `withdrawable: false`, of a name of the type in `submit.type` of the run's process version or the work item's, or of a name whose newest version a member approved at a gate |
| `422` | `withdrawal_with_files` | `type`, `message` | A withdrawal with one file or more |
| `422` | `unknown_decision` | `message` | A push's `decision` is not the id of a person's note on the run's work item |
| `422` | `invalid_artifact` | `names`, `message` | A file does not match the type's format, a video version has no video, a `proposal` version has no Markdown file or more than one, a run's version of `questions` or `review-comments` breaks a rule of check 7, such as a change to what members wrote or to a `decision`, a verdict's `answer` point is about a question that is not open, a verdict's `track.id` is a track the gate of the run's stage does not offer (`names` is `["track"]`), or a version of `acceptance-criteria` has a name other than `main` (`names` is `["name"]`) |
| `503` | `unavailable` | | The request could not be completed, such as a newest version of `questions` or `review-comments` that cannot be read; try again |

The messages:

- `run_ended`: "The run has ended, so it can no longer push artifacts or give a verdict."
  For a run a member cancelled: "The run was cancelled, so it can no longer push
  artifacts or give a verdict."
- `run_ended`, for a report of pushed commits: "Start a new run to record pushed commits.
  This run ended, so it records no more commits."
- `run_ended`, for a next-session request: "Close the run. It ended, so it starts no more
  sessions." For a run a member cancelled: "Close the run. A member cancelled it, so it
  starts no more sessions." For a ticket that is no longer kept: "Close the run. The ticket
  of its work item is no longer in Qory Apiary, so the run ended." For inputs that cannot
  be formed: "Close the run. The input of its next session breaks a rule for the agent's
  input, such as its size limit, so the run ended."
- `session_mismatch`: "Send the number of the session that ended last. A later session of
  this run ended already."
- `invalid_request`, for a next-session request: "Send session, state and reason as the
  run contract's next-session request has them."
- `not_writable`: "Record pushed commits only from a run with write access. This run cannot
  push."
- `invalid_request`, for a report of pushed commits: "Send 1 to 64 repositories, each with
  system, path and a full commit id of 40 or 64 lowercase hex characters."
- `unknown_type`, for a custom name: "Define the artifact type demo-findings in the
  workspace's Artifact types, then run the round again."
- `unknown_type`, for a standard type the workspace hides: "Switch on the artifact type
  mockup in the workspace's Artifact types, then run the round again."
- `no_version`: "Withdraw only a stored artifact. demo-script/scenario-2 has no
  version outside cancelled runs."
- `already_withdrawn`: "Leave demo-script/scenario-2 as it is. Its newest version, v3, is
  already a withdrawal."
- `person_version`: "Leave demo-script/scenario-2 to a member. Its newest version, v2, is
  a version by dana, and a run withdraws only a name whose newest version a run wrote."
- `type_not_withdrawable`: "Push a new version of questions instead. Qory Apiary reads
  questions, review-comments, verdict and proposal itself, so a run cannot withdraw
  them."
- `type_not_withdrawable`, for a type with `withdrawable: false`: "Push a new
  version of demo-script instead. The artifact type demo-script has withdrawable set to
  false, so a run cannot withdraw its names."
- `type_not_withdrawable`, for the type in `submit.type` of the run's process version:
  "Push a new version of submission instead. Qory Apiary reads its newest version as the
  run's submission, so a run cannot withdraw it."
- `type_not_withdrawable`, for a name whose newest version a member approved: "Push a new
  version of demo-script/scenario-2 instead. A member approved its newest version, v3, so
  a run cannot withdraw the name."
- `withdrawal_with_files`: "Push either files or a withdrawal. A withdrawal of
  demo-script/scenario-2 stores no files, and the push has 1 file."
- `unknown_decision`: "Set decision to the id of a person's note on this work item, from
  notes in GET work-item, or leave decision out."
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
    - "Shrink sources.json to at most 1048576 bytes."
    - "Make sources.json valid JSON. The file does not parse as JSON."
    - "Fix sources.json to match the format of proposal sources: at #, additional
      properties are not allowed but found property 'items'." The part after the colon
      is the JSON pointer of the first failing value and the text of the failed check: a
      schema check, or a check outside the schema such as a key that comes twice in an
      object ("the object has the key <key> twice", check 6).
  - For a run's version of `mockup` with `screens.json`, the message of the first
    rule the version breaks, with the fix first, such as "Remove the `<script>` element
    from `home.html` (screen `home`): a mockup page runs no script."
  - For a version of `verdict` whose `answer` point is about a question that is not open:
    "Push the questions first, or point at an open question in verdict.json: point 2 is
    about question q7, which is not open."
  - For a version of `verdict` whose `track.id` is a track that the gate of the stage the
    version is made in does not offer, `names` is `["track"]` and the message is, for a
    gate that offers tracks, "Set track.id to a track that the gate of Shape offers
    (standard, fast-track), or leave track out of the verdict. The track express is not
    offered.", and for a gate that offers none, "Leave track out of the verdict: the gate
    of Shape offers no track." A stage the process version does not have reads "the run's
    stage" as its name. The check is the same for `POST verdict` and for `POST artifacts` with the type
    `verdict`.
  - For a version of `acceptance-criteria` under a name other than `main`, `names` is
    `["name"]` and the message is "Name the acceptance criteria main: a work item has one
    set of acceptance criteria, and this push has the name other."
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
      its context and about while it stays decided or answered: to change them,
      withdraw the question and add a new one."
  - For a version of `questions` whose `about` points at an output or an item that the
    work item does not have, the fix first:
    - No such output: "Set about of question q4 in questions.json to an output of this
      work item, or to {"work_item": true}: the work item has no screenshot named
      scenario-2."
    - No such criterion in any version of the acceptance criteria, a removed one
      counting: "Set about.item of question q4 in questions.json to a criterion id of
      acceptance-criteria named main: no version of it has ac-9."
