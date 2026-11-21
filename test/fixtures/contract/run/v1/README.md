# Run contract, v1

What the control plane tells qory about a run, and what qory reports back. The files in
this directory are the schemas and the fixtures that a writer and a reader are tested
against. The folder `fixtures/check` has run documents that the schema accepts and
`Documents.Check` refuses, because the schema cannot express the rule they break.

| Schema | Document |
|---|---|
| `documents.schema.json` | the run's documents, which the machine receives with the run key |
| `next-session-request.schema.json` | the request that qory sends after a session ends |
| `next-session-answer.schema.json` | the next session of the run, or the end of the run |
| `next-session-refusal.schema.json` | the control plane's coded refusal of the request |
| `outcome.schema.json` | how the run ended |

## Settings of the workspace type

`type_settings` in the run documents and in the next-session answer contains the settings
that belong to the type of the workspace. This contract lists none of its members. The
process of the workspace type registers the schema of `type_settings`, and the schema of
the software factory requires `full_suite` in it.

## Members a reader does not define

A reader ignores a member that the schema of a document does not define, at any depth.
The rule covers the run documents, the next-session answer and the next-session request.
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
`documents.schema.json`, `next-session-answer.schema.json`,
`next-session-request.schema.json` or `outcome.schema.json`.

`contracts.CheckMustUnderstand` applies the rule to a document that a reader decodes into
a Go type. It resolves each pointer through the `json` tags of the type.

## Next-session refusals

`next-session-refusal.schema.json` has nine codes. An unsigned 401 or 415 from Qory
Apiary is outside them, because the gateway always signs its requests and sends JSON.
