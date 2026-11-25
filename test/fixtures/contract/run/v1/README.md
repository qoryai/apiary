# Run contract, v1

What the control plane tells qory about a run, and what qory reports back. The files in
this directory are the schemas and the fixtures that a writer and a reader are tested
against. The folder `fixtures/check` has documents that the schema accepts and that the
`Check` method of their Go type refuses, because the schema cannot express the rule they
break: `Documents.Check`, `Findings.Check`, `FindingsPost.Check` and
`FindingsPostAnswer.Check`.

| Schema | Document |
|---|---|
| `documents.schema.json` | the run's documents, which the machine receives with the run key |
| `next-session-request.schema.json` | the request that qory sends after a session ends |
| `next-session-answer.schema.json` | the next session of the run, or the end of the run |
| `next-session-refusal.schema.json` | the control plane's coded refusal of the request |
| `outcome.schema.json` | how the run ended |
| `findings.schema.json` | the findings of the run's work item, with their events, and the base of each target |
| `findings-post.schema.json` | the batch of events that qory writes about the findings |
| `findings-post-answer.schema.json` | the id of each new finding, and the open blocking findings of each stage |
| `findings-refusal.schema.json` | Qory Apiary's coded refusal of a findings request, or of a verdict |

## Settings of the workspace type

`type_settings` in the run documents and in the next-session answer contains the settings
that belong to the type of the workspace. This contract lists none of its members. The
process of the workspace type registers the schema of `type_settings`, and the schema of
the software factory requires `full_suite` in it.

## Session numbers

A workflow session after session 1 starts only after a next-session answer with `next`
set to `session`. qory can run an agent hook as a session between two workflow sessions.
The hook session takes the next Forager session number, and qory sends no next-session
request for it, so the `session` numbers in the requests can have gaps. The `session`
numbers in the answers are the control plane's sequence numbers and have none.

## Members a reader does not define

A reader ignores a member that the schema of a document does not define, at any depth.
The rule covers the run documents, the next-session answer, the next-session request and
the three findings documents `findings`, `findings-post` and `findings-post-answer`. The
findings refusal has no `must_understand`.
It applies at the top level, and in `subject`, `run_settings`, each entry of `deliver`,
`harness`, `model_choice` and each other object inside them.

- `must_understand` lists the members that the reader must understand. Each is a JSON
  Pointer ([RFC 6901](https://www.rfc-editor.org/rfc/rfc6901)) counted from the document,
  such as `/run_settings/runtime` or `/subject/kind`. Write a pointer once.
- A reader refuses a document whose `must_understand` lists a pointer to a member that
  it does not define. The schema accepts a pointer to a member that the schema defines.
- Another schema defines the members below `inputs`, below `type_settings` and below
  `harness.harness.extensions`. The schema accepts any pointer there. No Go reader
  refuses a pointer such as `/inputs/zz` or `/type_settings/zz`, because both are free
  maps of the run.
- The control plane refuses a request whose `must_understand` lists a pointer that it does
  not define, with 400 `invalid_request`. A batch's `dev.qory.run.exited` can have an
  outcome whose `must_understand` lists a pointer that the outcome schema does not
  define. The control plane answers that batch with `400 invalid_request`, as Forager
  defines for a body its contract refuses. This contract defines no body for that
  refusal.
- The outcome has the members `state`, `reason` and `exit_code` of Forager's
  `dev.qory.run.exited`. A reader of the data of that event ignores a member that
  Forager's schema does not define, unless the data's `must_understand` lists it. The
  outcome schema accepts a member that it does not define. The control plane reads `state`,
  `reason` and `exit_code` from the event.
- A reader refuses a bad value of a member that it defines.
- `minProperties` counts members, defined or not. A harness selection with only an
  undefined member reads as empty. `exclude: {"zz": 1}` leaves nothing out. `only: {"zz": 1}`
  takes nothing, because `only` leaves out everything it does not list.
  Go writes such a selection back as `{}`, which the schema refuses, because
  `minProperties` is 1.

Examples:

- A run document has a top-level member that an older qory does not define. The older
  qory ignores the member and runs as before.
- A run document has `/subject/language`, a member of the `subject` that an older machine
  does not define. The older machine ignores it.
- The run document lists `/subject/language` in `must_understand`. The older qory refuses
  the run documents, and the run ends with `run_documents_invalid`.

A control plane's tests check its documents against a closed copy of the schema. The
closed copy refuses a member that the schema does not define, so a misspelled member
fails the test. It covers each object of the schema and of the integration contract that
it reaches by reference. `contracts.CompileRunClosed` returns the closed copy of
`documents.schema.json`, `findings.schema.json`, `findings-post.schema.json`,
`findings-post-answer.schema.json`, `next-session-answer.schema.json`,
`next-session-request.schema.json` or `outcome.schema.json`.

`contracts.CheckMustUnderstand` applies the rule to a document that a reader decodes into
a Go type. It resolves each pointer through the `json` tags of the type.

## Next-session refusals

`next-session-refusal.schema.json` has nine codes. An unsigned 401 or 415 from Qory
Apiary is outside them, because the gateway always signs its requests and sends JSON.

## Findings

A finding is one problem that a reviewer, a check, a criterion, a scenario or a hook
raised about a target of the run's work item. Qory Apiary keeps the findings and mints
their ids. qory reads them with `GET /v1/runs/<id>/findings` and writes them with
`POST /v1/runs/<id>/findings`.

- A finding has a `state`: `open`, `fixed`, `dismissed` or `accepted`. Its `stage` is the
  stage that owns it. Only an open finding with `severity` `blocking` keeps its stage from
  passing. A finding of another stage, and a `non-blocking` finding, never does.
- An event is one line of the history of a finding. Events are only added. The `round` of
  an event is the `stage_round` of the work item when the event was written, and the
  `stage` is the stage that counts the round.
- qory writes `raised`, `repeated`, `replied_fixed`, `replied_disputed`, `closed_fixed`,
  `closed_dismissed` and `repeated_after_person_close`, and `reopened` when a reviewer
  repeats a finding that a run closed or a check fails again after `closed_fixed`. A person writes `dismissed_by_person`, `accepted`,
  `sent_back` and `reopened`. The run API does not write a person's events. Each event of
  a POST has `by`: the role of the session whose report the event comes from, such as
  `code-reviewer`, or the name of the check, such as `suite`. For a criterion, `by` is
  `locked-checks`, and for a scenario it is `demo-evidence`. Qory Apiary copies `by` to
  the `name` of the actor of the event that it writes. The actor of a person has no
  `name`.
- A finding that a person closed with `dismissed_by_person` or `accepted` cannot be
  reopened through the run API. A run that repeats it adds `repeated_after_person_close`,
  and the finding stays closed. `sent_back` keeps a finding open.
- A take in is one start of the work item in Qory Apiary. Taking the work item in again
  starts a new take in, and `findings` and `bases` are those of the current one.
- The base of a target is the version that the first run of the take in on the target
  started from. Qory Apiary stores it once for each take in and each target, from the
  first POST that has it, and refuses a different base later with `base_changed`. A target
  with no earlier version has no entry in `bases`.

`POST` answers with `findings-post-answer.schema.json`. A stage with no open
blocking finding has the count 0 in `open_blocking`, or is not listed. qory sends a
verdict `passed` for a stage only then.

### Findings refusals

`findings-refusal.schema.json` has four codes: `invalid_request` (400, with `names`),
`not_found` (404), `base_changed` (409) and `open_blocking_findings` (409). The other
members are as in Forager's link refusal. Qory Apiary answers a verdict `passed` of a stage
with `open_blocking_findings` while the stage owns an open blocking finding, at
`POST /v1/runs/<id>/verdict`. `stage` is the stage, and `findings` has the ids of up to 50
of the findings, and `message` is required. A verdict `changes-requested` or `escalate`
is not refused for this cause. The `message` has two lines. For two ids, they are:

```
Send changes-requested in place of passed: build has 2 open blocking findings.
  The open blocking findings are f1, f2.
```

For one id, they are:

```
Send changes-requested in place of passed: build has 1 open blocking finding.
  The open blocking finding is f1.
```

The schema cannot check that no two events of a batch have the same `ref`, that no two
findings have the same id, or that no list of bases, created ids or stages repeats an
entry. `FindingsPost.Check`, `Findings.Check` and `FindingsPostAnswer.Check` check them.
