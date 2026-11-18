# Integration contract, v1

What a program of an integration reports about itself, and how it is handed its settings.
A reader, `qory` or a control plane, finds and sets up every integration the same way:
the `qory-<name>` programs that Qory publishes and the programs you keep in any other
repository alike. The machine's configuration declares each integration and the program
that serves it; the reader runs `<program> describe` and expands the definitions from the
answer alone. This directory is the contract: the description's JSON schema and the
fixtures a program or a reader is tested against.

## Versions

The description contains `version: 1`, an integer, and its schema is addressed by URL
under `https://qory.dev/contracts/integration/v1/`, as Forager's documents are
([§Versions](https://github.com/qoryai/forager/tree/v0.7.0/contracts/forager/v1#versions)).
A reader reads the versions it knows and refuses a description of any other. An
addition keeps `version` 1; a change that breaks a reader is `version` 2.

## Describe

```sh
<program> describe
```

prints one JSON document, `description.schema.json`, and exits 0. It takes no settings
and reaches no network, so a reader runs it before it has any and a form is drawn
from it.

| Field | |
|---|---|
| `version` | `1`, the contract's version |
| `name` | the integration's name, `^[a-z0-9][a-z0-9_-]{0,63}$`: the key it is declared under, such as `github`, unless the machine chooses another. The key is the name of the gateway's credential, `^[a-z0-9][a-z0-9_.-]{0,63}$`, and of a program Qory publishes, `qory-<key>`, so the name is the credential's grammar without the dot, which in a program's name reads as an extension |
| `title`, `description` | human text, for a form or a listing; `description` may be absent |
| `vendor` | the vendor's name, 1 to 40 characters, such as `Anthropic`, for lines the control plane shows, such as `Anthropic rejected it on <date time>.`; a line may start with it, and the control plane then writes its first letter in upper case; may be absent |
| `domains` | the domains the integration works with, each a domain name, `^[a-z][a-z0-9-]{0,63}$`, such as `software`, the domain of software work; at least one and none twice; may be absent |
| `program_version` | the program's version, a string, such as `0.1.0` |
| `settings` | a JSON Schema, draft 2020-12, of type `object`: the settings document the program takes |
| `roles` | the roles the program plays, an object keyed by the role's name; at least one |

```json
{"version": 1, "name": "acme-tracker", "title": "Acme tracker", "program_version": "0.1.0",
 "settings": {"type": "object"},
 "roles": {"credential": {"argument": "[A-Z]+", "hosts": ["tracker.acme.example"]}},
 "egress_hosts": ["tracker.acme.example"]}
```

**Domains.** `domains` lists the domains the integration works with, each a domain name, for example `software`, the domain of software work; `qory-github` declares `["software"]`. When the integration names no domain, the field is absent, never an empty list, which the schema refuses. The domains apply only to where work comes from, never to a credential or to a place a workspace reads its configuration from: a credential of the `credential` role reaches a run in a workspace of any domain.

**Secrets.** A property of the settings marked `writeOnly: true` is a secret. A form
shows it as one, written and never read back, a log leaves it out, and it stays off
every command line. A secret is a property of the settings document itself, never one
nested in another, so a reader finds every secret among the settings' `properties`.
Every secret `<name>` has a setting passed on a command line in its place,
`<name>_file`, a file that contains it: for example the secret `private_key` and the
setting `private_key_file`.

## Settings

Every role is started the same way, so a reader needs no template language:

```sh
<program> <role> --settings <json> -- [the role's arguments]
```

`<json>` is one word of the command line containing the settings document, valid against
the description's `settings`. A program reads its settings from there and from nowhere
else, and keeps none of them. `--` ends the flags, as it does for Go's `flag` package and
POSIX `getopt`, and a program takes it so: an argument a policy defines is never read as
a flag, whatever it starts with.

A command line is visible to the machine's other processes, so the settings passed on a
command line contain no `writeOnly` value. A secret reaches a program as a file whose
path the settings define, such as `private_key_file`, readable by the program's user
alone. A program refuses a `writeOnly` value it receives on its command line, and reports
which setting, never the value.

The gateway replaces `${argument}` wherever it appears in an adapter's argument, so a
reader writes every `$` of the settings as `\u0024`, JSON's escape for the same
character: `${argument}` in a setting reaches the program as written, and never as the
policy's argument.

## Exit status

`describe` and every role end the same way. On success a program exits 0 and prints one
document on standard output, the description or the one the role's contract specifies,
and nothing else there. On failure it exits non-zero, prints nothing on standard output,
and writes one line on standard error describing what failed, never a secret. The reader
reports that line as the reason it refuses the declaration when `describe` fails, and the
gateway reports it as the reason it refuses the run when a role fails.

## Roles

A reader expands the roles it knows and leaves the others as they are, so one
description serves readers that know different roles.

| Role | Defined | Started as |
|---|---|---|
| `credential` | here | `<program> credential --settings <json> -- ${argument}`: exactly the adapter of a gateway definition |

### Credential

The gateway's credential adapter
([§Credentials](https://github.com/qoryai/forager/tree/v0.7.0/contracts/forager/v1#credentials)):
the program mints or fetches a token for the argument a run's policy defines and prints
the gateway's credential document.

| Field | |
|---|---|
| `argument` | a regular expression, RE2, the policy's argument must match whole: the definition's `argument` |
| `hosts` | the hosts the adapter answers for, at least one: the definition's `hosts`, the most an answer may claim |

`conformance.Credential` checks the printed document against the gateway's schema, and
refuses an `apply` entry of the scheme `header` whose `header` is one it reserves: a name
in `conformance/headers.json`'s `refused`, or one that starts with a prefix in its
`refused_prefixes`, compared in lower case.

## Declaring an integration

`qory` reads the `gateway.integrations` section of a machine's `forager.yaml`:

```yaml
gateway:
  integrations:
    <key>:
      program: <program>     # may be left out when the program is qory-<key> on the PATH
      settings: {...}        # the settings document; absent is {}
```

A reader expands each declared integration:

1. The program is `program`. Absent, it is `qory-<key>`, found on the `PATH`. That fits an
   integration Qory publishes, declared under its name, such as `github` for
   `qory-github`. Any other integration defines its program, by a path or a name on the
   `PATH`, and so does one of Qory's declared under another key.
2. It runs `<program> describe` and refuses the declaration unless the program exits 0
   with a description this schema accepts.
3. It checks the settings against the description's `settings`, and refuses a
   `writeOnly` value among them, since every role it expands is started with them on a
   command line.
4. For the `credential` role it defines the credential `<key>`:
   `adapter: [<program>, credential, --settings, <json>, --, "${argument}"]`, with
   `<json>` the settings as compact JSON, every `$` in it written `\u0024`, and the
   role's `argument` and `hosts`. Written in YAML, `<json>` is a single-quoted scalar,
   in which nothing is an escape but a quote, doubled, so the word reaches the gateway as
   it was written.
5. It expands the roles it knows, and leaves a description's other roles as they are.

Declared:

```yaml
gateway:
  integrations:
    github: {settings: {app_id: 123456, private_key_file: /etc/qory/github-app.pem}}
    tracker: {program: /opt/acme/bin/acme-tracker, settings: {project: "it's $X"}}
```

`qory-github describe` answers [`fixtures/github.json`](fixtures/github.json) and
`/opt/acme/bin/acme-tracker describe` answers
[`fixtures/acme-tracker.json`](fixtures/acme-tracker.json), and the declaration expands
to the gateway's definitions:

```yaml
gateway:
  credentials:
    github:
      adapter: [qory-github, credential, --settings, '{"app_id":123456,"private_key_file":"/etc/qory/github-app.pem"}', --, "${argument}"]
      argument: '[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}(,[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100})*'
      hosts: [github.com, api.github.com]
    tracker:
      adapter: [/opt/acme/bin/acme-tracker, credential, --settings, '{"project":"it''s \u0024X"}', --, "${argument}"]
      argument: '[A-Z]+'
      hosts: [tracker.acme.example]
```

The tracker's `$X` is written `\u0024X`, which JSON reads as `$X`, and the quote of
`it's` is doubled in the single-quoted scalar: the program reads `it's $X`.

A run's policy selects them by the key, as it selects any credential:
`{name: github, argument: acme/shop}`.

## Change feed and comments

A source adapter reads its change feed with the signed
`GET /v1/work-items/changes?after=<cursor>` (`changes.schema.json`). The control plane
ends the feed answer's entries before the answer's body passes 4194304 bytes (4 MiB).
The feed answer has at least one entry whenever the feed has an entry of a kind that the
revision in the request's `X-Qory-Contract-Version` defines after the cursor. The
adapter reads the next entries from the feed answer's `cursor`.

The control plane writes a `watch` entry, with `work_item_id` and `url`, and a
`submission` entry, as [Submissions](#submissions) describes, whenever a run stores a
submission version. It writes both entries in the feed of the adapter of the run's
target collection, whatever source the work item came from, and also when the work item
came from no item at a source. It writes a `watch` entry only for an adapter whose
`source` role has `targets: true`, and a `submission` entry only for an adapter whose
`source` role has `submissions: true`. An adapter that does not set `submissions: true`
never receives a `submission` entry.

## Submissions

A submission is the work item's branch at its head commit, with the commits that the run
made. When a run stores a submission version, the forge's adapter, an adapter whose
`source` role has `submissions: true`, reads it from the change feed and puts it on
the forge. The adapter runs no program. A `system` is a host name without a port, so a
forge on a port other than 443 is not a target. The steps:

1. The control plane stores the submission version and writes a `submission` entry to
   the feed of the adapter of the run's target collection (`changes.schema.json`). The
   entry has `submission_id`, `targets` and `text`. Each target has `system`, `path`,
   `branch`, `base` (`commit` and `branch`), the head `commit`, `commits` (each with
   `commit` and the ledger `step`) and `draft`: `{action: open}` or
   `{action: update, number}`. `text` and `draft` are absent after a session that did
   not pass, when the run wrote no text, and when the session escalated: the adapter then
   only builds the address of each commit. A draft is a
   pull request or a merge request that people can still change before it is ready.
   The entry is the same for every forge, so one adapter opens a pull request and
   another a merge request from it.
2. The adapter builds the forge's address of `base.commit` and of each commit, for every
   target, whether or not the session passed.
3. For a target with `draft`, the adapter opens the draft, or edits the draft with that
   `number`. The `number` is a hint: when the forge has no draft with that number, the
   adapter finds the draft from `branch` in any state and goes on with it, or opens a
   draft if there is none. With `open`, the adapter first looks for a draft from `branch`
   in any state, so a draft that exists is not opened a second time. The adapter finds a
   draft by its head branch, `branch`, and the repository only, never by `base.branch`. With several drafts on the branch, the adapter takes the entry's `draft.number` when it is among them, otherwise the not-closed, not-merged draft with the highest number; with none, the closed or merged one with the highest number, reported as kept. The adapter edits a
   draft only while it is `draft` or `open`; a draft that a person closed or merged stays
   as it is. The draft's description has one block between the lines
   `<!-- qory:start -->` and `<!-- qory:end -->`, and `text.description` is the content
   of that block. On an update, the adapter takes the first end marker line that has a
   start marker line before it, and the last start marker line before that end line. It
   replaces the text from the start line to the end marker with the new block, and keeps
   the rest of the description. If there is no such pair, as when a person removed a
   marker, the adapter adds a blank line and a new block at the end. The new block uses
   the line ending of the description, CRLF when its first line ending is CRLF and
   otherwise LF, for the line endings that the adapter adds: the ones next to the two
   marker lines, and the blank line before a block added at the end. The line endings
   inside `text.description` stay as given. On an update, the adapter sets the title
   to `text.title` only while the draft's title equals `previous_title`, the
   `text.title` of the previous version; a title that a person edited stays. If the
   forge adds a text before the title of a draft that is not ready, the adapter compares
   the title without it. The adapter reads the draft's state before it edits. `ref`, when
   present, is the ref of the source item that the work item was taken from, for an
   adapter that links the draft to that item.
4. The adapter sends `POST /v1/work-items/changes/submitted`
   (`changes-submitted.schema.json`) with `submission_id` and, for each target that did not fail, the
   `commit_url` of each commit and of the base, and, for a target that had `draft`,
   `draft`: `{number, url, title, state, action}`. `state` is `draft`, `open`, `closed` or
   `merged`. A draft that a person closed or merged has the action `kept`. The `number`
   may differ from the entry's. The reply has `draft` exactly when the entry's target had
   a draft; the control plane refuses a reply that does not, 400. The control plane
   stores the addresses and the draft.
5. After a failure that trying again cannot fix, or when its retries end, the adapter
   sends `POST /v1/work-items/changes/failed` (`changes-failed.schema.json`) with
   `submission_id`, `system`, `path`, `reason` and, optionally, `detail`: one line of 1
   to 1000 characters with what to do first, then the forge's status and message. The
   adapter never puts an access token, a secret or a header in `detail`. A report about
   a comment has no `detail`.

| `reason` | Meaning |
|---|---|
| `not_permitted` | the forge returned that the integration's account has no permission on the repository |
| `unreachable` | each request to the forge timed out, failed to connect, or returned a busy status or a 5xx status, until the adapter's retries ended |
| `branch_gone` | the forge returned that the branch or its base branch does not exist |
| `too_long` | the title or the description is longer than the forge's limit for a draft |
| `forge_refused` | the forge refused a request with a status that no other reason covers, such as 400, or 422 for a cause other than a missing branch or a length limit, so the same request fails again. The adapter gives the forge's status and message in `detail`, with the fix first |

On a run with no run code, `qory run` runs a submit program with the login of the forge's
command line that the person made. That run has no work item and no earlier submission,
so the program opens a draft from the branch that qory made for the run and pushed (`QORY_SUBMIT_BRANCH`, `qory/run-<run id>` unless that name is taken),
or edits the draft that it finds there, and builds the address of each commit as in step
2. The program sends nothing to the control plane: only the adapter sends
`changes/submitted`. The [submit program contract](../../run/v1/submit-program/README.md)
lists its inputs and its result lines, and has the rule of the block in the same words.

A person can write a comment in the control plane on a work item taken in from an item
at the source. The comment reaches the source in four steps:

1. The control plane stores the comment with the item's other comments and writes a
   `comment` entry to the feed, with `comment_id`, `ref`, `author_name` and `body`.
   `comment_id` is `sc_` and 16 lower-case Crockford base32 characters.
2. The adapter posts the comment on the item as the integration's account at the
   source. The first line is `<author_name> wrote in Qory Apiary:`, such as
   `Dana Example wrote in Qory Apiary:`, then an empty line, then `body` unchanged.
   `author_name` is plain text, and the control plane sends it as it is, with no
   escaping. The adapter writes it as plain text: it escapes each character or sequence
   that the format of the source's comments would read as markup, as a mention, or as a
   link. For a source whose comments are Markdown, that includes an @ at the start of a
   word, a code fence, leading spaces, the start of an HTML comment, and a sequence that
   the source turns into a link, such as a reference to another item (`ABC-123`, `#123`)
   or a commit id. The escaped name, the other 22 characters of the first line
   (`" wrote in Qory Apiary:"`), the two line breaks after it, and the mark with any line
   break before it are at most 536 characters together. 536 is the room that `body`, at
   most 65000 characters, leaves of the 65536 characters in `definitions.schema.json`,
   `$defs.body`. For example, an escape of at most 3 characters for each character of the
   name, such as a backslash before a character and a zero-width space after it, keeps a
   name of 100 characters at most 300 characters. A numeric character reference for every
   character, such as `&#64;`, makes the name 500 characters or more and leaves too
   little room for the mark. The adapter puts a mark that contains the `comment_id` in
   the posted comment. Before it posts, it checks the item for a comment with that mark.
   So it posts at most one comment per `comment_id`, however often it reads an entry with
   that `comment_id`, and the comment of a post whose result is unknown, such as one that
   timed out, is not posted a second time. The form of the mark is the adapter's choice:
   the source must keep it, and where the source allows, people who read the comment do
   not see it.
3. The adapter sends the posted comment back with `POST /v1/source-items/comments`, with
   `comment_id` set (`source-item-comments.schema.json`). The control plane matches the
   sent comment to the comment it stored, and stores no second comment.
4. After a failure that trying again cannot fix, or when its retries end, the adapter
   sends `POST /v1/work-items/changes/failed` (`changes-failed.schema.json`) with
   `comment_id` and `reason`. The control plane marks the comment not posted and stores
   `reason`.

| `reason` | Meaning |
|---|---|
| `item_gone` | the source returned that the item does not exist |
| `not_permitted` | the source returned that the integration's account has no permission to comment on the item |
| `too_long` | the comment with its first line is longer than the source's limit for a comment |
| `unreachable` | each request to the source timed out, failed to connect or returned a busy status, until the adapter's retries ended |

The control plane writes comment entries only for a source whose `source` role has
`comments: true`. An adapter that does not set `comments: true` never receives a
`comment` entry: the source takes no comment from the control plane, so the adapter
cannot post comments there, and the comment stays in the control plane only. A source
with `items: false` has no items, and its `source` role has no `comments`.

## Fixtures

| Path | Contains | Validated against |
|---|---|---|
| `fixtures/*.json` | descriptions that are accepted: `github.json`, what `qory-github describe` printed at commit c8a3ea5, built with `go build -buildvcs=false`, so its `program_version` is `dev`, with `egress_hosts` added; `acme-tracker.json`, a description with the members every description must have, plus `egress_hosts` for its credential host; `acme-chat.json`, one that serves two domains; `unknown-role.json`, one with `acme_role`, a role the contract does not define, beside `credential`; `example-source-apply-bearer.json`, a source role with an apply item of the scheme `bearer` whose paths are templates with `{target.path}` and a path without it; `example-source-apply-basic.json`, one with an apply item of the scheme `basic` and its `username`; `example-source-apply-header.json`, one with an apply item of the scheme `header` and its `header`, on a DNS name and an IPv4 address; `example-source-guide.json`, a source role with a `guide`: a `setup` part with `before`, three `steps` and `after`, and a `connect` part with two `steps` alone; `example-source-targets.json`, a source role with `targets: true`; `example-source-submissions.json`, a source role with `targets: true` and `submissions: true`; `example-source-comments.json`, a source role with `comments: true` | `description.schema.json` |
| `fixtures/adapter/<name>/` | the requests and answers of the adapter, named by their schema; among them `changes/submission-github-like.json` and `changes/submission-gitlab-like.json`, a submission entry that opens a draft on one host and one that updates a draft on another, `changes/submission-two-versions.json`, a first version with no `previous_title` and a second that has the title of the first, `changes-submitted/github-like.json` and `changes-submitted/gitlab-like.json`, the replies, and `changes-failed/submission-*.json`, one for each reason of a submission | `<name>.schema.json` |
| `fixtures/invalid/` | descriptions the schema refuses, named `description-<reason>`; among them `description-source-apply-host-wildcard.json`, an apply host with `*.` in front; `description-source-apply-header-without-header.json`, the scheme `header` without `header`; `description-source-apply-username-with-bearer.json`, a `username` with the scheme `bearer`; `description-source-apply-path-two-placeholders.json`, a path template with `{target.path}` twice; `description-source-apply-path-star-before-placeholder.json`, a path template with `*` before `{target.path}`, outside Forager's path grammar; `description-source-apply-path-star-after-placeholder.json`, a path template with `*` right after `{target.path}`, in the same segment; `description-source-guide-steps-11.json` and `description-source-guide-steps-empty.json`, a guide part with 11 steps and with none; `description-source-guide-no-steps.json`, a guide part without `steps`; `description-source-guide-line-feed.json`, a guide line with a line feed; `description-source-guide-301-characters.json`, a guide line of 301 characters; `description-source-guide-undefined-member.json`, a guide part with a member the schema does not define; `description-source-comments-false.json`, `comments: false`; `description-source-submissions-false.json`, `submissions: false`; `description-source-submissions-string.json`, `submissions` as the string `"true"`; `description-source-submissions-without-targets.json`, `submissions: true` with no `targets`; and `description-source-items-false-with-comments.json`, `comments` beside `items: false` | `description.schema.json`, expecting a failure |

Every fixture is synthetic. No host name of anyone's infrastructure and no real secret.

## Sources

- [JSON Schema 2020-12](https://json-schema.org/draft/2020-12/json-schema-validation),
  §9.4 for `writeOnly`.
- Forager's contract, [§Credentials](https://github.com/qoryai/forager/tree/v0.7.0/contracts/forager/v1#credentials),
  for the adapter definition a credential role expands to.
