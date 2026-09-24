# The server contract as the apiary implements it

What the discovery endpoint and the events endpoint expect and return. The contract is `contracts/runner/v1` of the
`qoryai/runner` repository, revision 1; this page is the apiary's reading of it, and where the
two disagree the contract wins. Anything the contract has not fixed is listed under "Assumed"
at the end.

## Signed GET

Every GET of a contract endpoint carries these headers:

| Header | Value |
|---|---|
| `X-Qory-Access-Key` | the key id, `ak_` and 16 lowercase Crockford base32 characters |
| `X-Qory-Timestamp` | the Unix time in seconds, UTC, as a decimal integer with no fraction |
| `X-Qory-Signature-256` | `sha256=` and the lowercase hex HMAC SHA-256 of the canonical string, keyed with the secret |
| `X-Qory-Contract-Version` | optional; the contract version the runner implements, a decimal integer |
| `User-Agent` | `qory-runner/<version>`; the version is recorded on the key |

The canonical string is three lines joined by `\n` with no trailing newline:

```
GET
/.well-known/qory-configuration?a=1
1700000000
```

1. the method, upper case;
2. the request path, followed by `?` and the query string only when the query string is
   non-empty, both exactly as sent on the wire (no decoding, no re-ordering, no trailing
   slash added or removed);
3. the value of `X-Qory-Timestamp` as sent.

Known answer: the key `test-secret` over `GET\n/.well-known/qory-configuration?x=1\n1700000000`
gives `sha256=e8cc6260e2740e9282f2b45fa8bc590e3afe0e59eb53882b19cdb0f87a613c02`.

The timestamp is accepted when `|server now - timestamp| <= 300` seconds. Either of a key's
two secrets verifies: after a rotation the previous secret keeps working until it is retired
or the key is revoked.

## The discovery document

`GET /.well-known/qory-configuration`, signed as above, answers `200` with
`Content-Type: application/json` and the header `X-Qory-Configuration: sha256=<lowercase hex>`,
the SHA-256 of the body as sent:

```json
{
  "version": 1,
  "events": {"url": "https://<public host>/v1/events", "types": ["*"]},
  "run": {"url": "https://<public host>/v1/run-configuration"}
}
```

`<public host>` is the application's public base URL (`PUBLIC_URL`). The `events` URL is
the events endpoint below, and the `run` URL the run configuration endpoint after it.

The `run` section is there only for a hive whose policy somebody has made: a hive with at
least one change in its policy's history, the first rule or the first change of mode, in the
hive or in any one repository: the first change anywhere starts serving every repository of
the hive, the others the hive's baseline. A hive nobody has given a policy is answered the document without `run`, and its machines run under
the policy of their own `runner.yaml`, as the contract has it for a server that names no
section. So an upgrade, or a hive nobody has looked at, never replaces a machine's own
enforcement with an empty policy. The document is therefore one of two, by hive, and so is
its digest, here and in every answer to a batch. The first change of a hive's policy changes
that digest: a run in flight fetches the document again, finds the section, fetches its run
configuration and applies it, which is the moment the hive takes over. It does not go back:
a hive whose rules were all removed again still serves its (empty) policy. Sections a runner
does not know are to be ignored.

## Signed POST: the events endpoint

`POST /v1/events`, one batch of one run's events per request, with these headers:

| Header | Value |
|---|---|
| `X-Qory-Access-Key` | the key id |
| `X-Qory-Signature-256` | `sha256=` and the lowercase hex HMAC SHA-256 of the raw request body, keyed with the secret |
| `Content-Type` | `application/cloudevents-batch+json` |
| `X-Qory-Delivery` | a UUID per batch; a retry of the batch carries the same one |
| `X-Qory-Contract-Version` | optional; `1` |
| `X-Qory-Run-Configuration` | optional; the digest of the run configuration the run holds, `sha256=<hex>` |
| `User-Agent` | `qory-runner/<version>` |

No timestamp is signed and no window is checked; a `X-Qory-Timestamp` on a POST is ignored.
The signature is verified over the bytes as received, before anything parses them. Either of
the key's secrets verifies.

A request is refused in this order, the order of the contract's reference receiver, and the
first refusal that applies is the answer:

| Status | When | Body |
|---|---|---|
| `413` | the body is over 2 MiB (2 097 152 bytes), or cannot be read | `{"error":"payload_too_large"}` |
| `401` | any failure of authentication (see Failure) | `{"error":"unauthorized"}` |
| `415` | the content type is not `application/cloudevents-batch+json` (its case and any parameters are ignored) | `{"error":"unsupported_media_type"}` |
| `429` | the key has delivered more than its rate; `Retry-After` says how many seconds to wait | `{"error":"rate_limited"}` |
| `400` | `X-Qory-Contract-Version` is sent and is not an integer from `1` up (a later revision than the server knows is accepted) | `{"error":"unsupported_contract_version","supported":[1,2]}` |
| `400` | the body is not a batch, or is over a limit below | `{"error":"invalid_batch"}` |
| `410` | the hive has closed the run, or retention has pruned the run's events: the delivery is recorded, no event is stored | empty |
| `503` | the batch could not be stored; nothing of it was | `{"error":"unavailable"}` |
| `202` | stored | empty |

Every `202` and `410` carries the digests in force: `X-Qory-Configuration`, the digest the
hive's discovery answer carries, and, for a hive whose policy somebody has made,
`X-Qory-Run-Configuration`, the digest of the run configuration for the run's repository (see
"The run configuration" below for which that is while the repository is not known yet). A
hive without a policy of its own is never answered the second. No other status carries it. No error body repeats anything that was sent. The ping is a batch like any other: a `2xx` lets the
run start, and a revoked key, a bad signature or an unsupported version does not.

A batch is a non-empty JSON array of at most 1000 objects (a runner cuts a batch at a
hundred), each with `id` and `subject` (lowercase UUIDs), `type` (beginning `ai.qory.`),
`sequence` (ten digits, from `0000000001`: `0000000000` is no sequence), `source`
(`urn:qory:run:` and the subject), `time` (RFC 3339, in the years 1970 to 9999) and `data`
(an object, nested no deeper than 64 levels), all of one subject. The limits are what the
tables hold: what passes them is stored, and no batch is answered `500`. Only this envelope is
checked: `data` is not validated against the schema of its type, and a type this release does
not know is stored like any other, so a newer runner's events are kept until a release reads
them.

What is stored, in one transaction, before the answer:

- the run, created on the first event of a subject the key's hive has not seen, in that hive,
  in state `pending`, with the key that delivered it and the versions the request named. The
  same subject under another hive is another run. Two first batches at once make one run.
  The run's row is locked while its batch is stored, so a close and a batch never cross: a
  close that commits first is answered `410`, and a closed run never gains an event;
- nothing, for a run retention has pruned. Deduplication is against the events the hive
  holds, and a pruned run holds none, so a batch delivered again after the prune could not
  be told from a new one and would be folded a second time. The hive therefore wants nothing
  more of a run whose events it pruned, and says so the way it does for a closed run: `410`,
  the delivery recorded, no event stored. A run that lost only its log output (the log's
  days are shorter than the events') still takes events, deduplicated against the ones it
  keeps, but no `ai.qory.run.log` event: its log events are gone, so a replayed one could
  not be recognised, and one that is new would be older than the hive keeps log output.
  Such events are answered like duplicates, within a `202`. Neither case arises for a run
  that is alive: retention only prunes a run that has ended or gone silent for days;
- each event, as received: `id`, `sequence` as an integer, `type`, `time`, `data`, and when it
  was received. An event already held (the same `id`) is skipped: delivery is at least once.
  An event whose `id` is held by another run of the hive, or whose `sequence` in its run is
  held under another `id`, is dropped and counted in a log line; it is never an error, since
  sending it again could not help. Events are read back by `sequence`, never by arrival;
- the delivery: the key, `X-Qory-Delivery`, the subject, how many events it held, how many were
  new, the status answered, and the batch's `X-Qory-Run-Configuration` when it had the shape
  of a digest. A delivery id the key has delivered before is answered `202` again and nothing
  is stored;
- on the run: the count of events, when the last one was received, and the last
  `X-Qory-Run-Configuration` that had the shape `sha256=` and 64 lowercase hex digits.

After the commit, and never failing the request: the key records the time, and the runner
version and the contract version when the request named them (a request that names none
leaves what is recorded); when the batch held a heartbeat that was new, the key records when
the server received it, by the server's clock and never the runner's. A repeated delivery
records nothing on the key. The run's events are projected into the run, its connections and its log, on the server's own
time. Nothing of a request's headers beyond the above is stored, and neither the signature nor
the body is logged.

## Signed GET: the run configuration

`GET /v1/run-configuration?<label>=<value>&…`, signed like discovery, the query signed as
sent. Every query parameter is read as one of the run's labels: a revision-1 runner sends
`forge` and `repository`, a revision-2 runner every label. The hive's body (`Apiary.Body`)
says which labels name the target; the software body's are `forge` and `repository`, so
both revisions are served alike. It answers `200`, `Content-Type: application/json`, with
`X-Qory-Run-Configuration: sha256=<lowercase hex>`, `ETag: "sha256=<hex>"` (the same string,
quoted), `X-Qory-Configuration` and `Cache-Control: no-store`:

```json
{"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["api.example"]}}}
```

With deny rules the `egress` section carries `deny` after `allow`, the hosts a runner denies
before it consults `allow` or the mode:

```json
{"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["*.example"],"deny":["tracker.example"]}}}
```

The body is the bytes that were stored when the policy was last changed; nothing is rendered
for a request, so the digest is of exactly what is sent. It is the configuration of the
key's hive for the repository the two labels name. A repository the hive has not seen, one
with neither rules nor a mode of its own, and a request that names none (or one label of the
two) get the hive's baseline. `egress.mode` is the hive's, unless the repository has set its
own, `observe` or `enforce`; a repository that has not follows the hive, later changes of the
hive's mode included, and a repository the hive has not seen gets the hive's. The rules
resolve the same under either mode: a locked rule of the hive holds in a repository's
document whatever its mode, and a deny holds in either mode, since `egress.deny` is decided
first: under `observe` a runner denies what `deny` names and nothing else, and `allow` says
what `enforce` would reach. A hive whose policy nobody has made serves none: `404`
`{"error":"not_found"}`, nothing rendered; discovery named it no `run` section, so a runner
does not ask. The endpoint spends a token of the key's rate limit, the events endpoint's
bucket: `429 {"error":"rate_limited"}` with `Retry-After` beyond it, which to a runner is no
run or a reload that failed and is tried again on the next answer.

Rendering is canonical: members in a fixed order (`mode`, `allow`, `deny`, `paths`), no
whitespace, `allow` and `deny` sorted with names before `*.` suffixes (so the rule a runner
reports for a connection is the most exact one), `paths` by host with each list sorted,
`credentials` by name; `allow` is always present, `deny`, `paths` and `credentials` only when
they hold something, so a policy without a deny renders the bytes it always did. The same rules give the same bytes
and the same digest, a change that renders the same bytes makes no new version, and every
document is validated against the contract's `run-configuration.schema.json` and
`policy.schema.json` (vendored under `priv/contract/`) before it is stored: a change whose
render the schema refuses is not made, and neither is one whose render is over 1 MiB, the
most a runner reads of a document (`MaxDocument`). A list holds at most 500 rules and a rule
at most 100 paths.

## The log and the terminal

`ai.qory.run.log` is stored like any event and its bytes, decoded, are the run's
`log_chunks`, one row a chunk, keyed by the event's sequence; `output.log` is their
concatenation in sequence order, which is what the log endpoint of the console streams. How
the runner cuts the chunks is its own affair and the apiary reads nothing into a boundary:
on pipes a chunk is one line or 4096 bytes and may end inside a multibyte character, on a
pseudo-terminal it is one redraw, 4096 bytes or a quiet gap of 50 ms after the runtime's
last write, never inside a character. The terminal of the run page hands the bytes to
xterm.js as bytes, so a character cut in two is still one character.

The size of the pseudo-terminal is in the record: `terminal` of `ai.qory.run.started`
(`cols`, `rows`, present exactly when `interactive` is true) and one `ai.qory.run.resized`
per change, at the sequence where the new size took effect, so the chunks before it were
written to the old size and the chunks after it to the new. The projection keeps the size
the record last said, `runs.terminal_cols` and `runs.terminal_rows`, the later of the start
and the resizes by sequence; a resize whose data is not a size (an integer in 1 to 65535 each)
changes nothing. The Details tab shows it. A resize is not an item of the timeline: the
terminal is where it matters.

The terminal tab replays at the recorded size. The bytes never cross the LiveView socket,
so the sequence of the resizes has to reach the reader beside the bytes: the log endpoint
answers one size at a time. `x-qory-log-size` (`<cols>x<rows>`) is the size in force right
after `after`, the last resize at or below it, else the start's; an answer stops short of
the next resize, and once every chunk before it is sent, `x-qory-log-through` is the
resize's own sequence, so the next question is answered at the new size. The reader sets the
screen to each answer's size before writing its bytes, and xterm.js reflows as a terminal
does. A resize that arrives after the chunks past it (delivery is in any order) is applied
on the next load, not to what is already on the screen.

A run without a size is a run on pipes, or one recorded by a runner before the size was
reported: the endpoint sends no size header and the page fits the screen to the box, as it
did before, with the wrap toggle. On pipes `stream` is `stdout` or `stderr`, never
`terminal`, and a single stream of a pipes run, or a download, is never sized.

## Failure

Every failure is `401` with the body `{"error":"unauthorized"}` and nothing else, whether
the cause is a missing header, an empty header, a key id that is not of the exact form
`ak_` and 16 lowercase Crockford base32 characters (including one that is not valid UTF-8;
such a value is refused before any lookup), a key id that does not exist, a revoked key,
a timestamp that is not an integer, a timestamp outside the window (both on a GET only), or
a signature that does not match. The body never says which. Nothing about the request's headers is logged.

On a successful GET the key records the time, the runner version from `User-Agent` (when it is of the
form `qory-runner/<version>`) and the contract version from `X-Qory-Contract-Version` (when
present and an integer). What is recorded never decides the answer:

- the runner version is kept to its first 80 characters; a `User-Agent` that is not valid
  UTF-8, or a version with non-printable characters, records no version;
- a contract version outside `0..32767` records no version;
- if recording the use fails, the request still succeeds.

No header value makes the endpoint answer `500`.

## Assumed

The contract has not fixed these; Apiary chose, and the runner should match:

- The hex in the signature is lowercase and compared byte for byte; an uppercase hex
  signature fails.
- The timestamp is compared to the server's clock with a symmetric window of 300 seconds;
  a timestamp in the future is treated like one in the past.
- The path in the canonical string is the raw request target as received, including any
  percent-encoding; nothing is normalised on either side. The query string joins with `?`
  only when non-empty, so `/path` and `/path?` sign differently.
- A header sent twice fails; the first value is not taken and the request is refused.
- `User-Agent` that is not `qory-runner/<version>` is accepted; only the recorded runner
  version is left empty. The same holds for a version that is not printable text, and a
  version longer than 80 characters is recorded truncated.
- `X-Qory-Contract-Version` is a decimal integer in `0..32767`; any other value is accepted
  and ignored, it does not fail the request.
- The discovery path is `/.well-known/qory-configuration`, without a trailing slash, and
  answers JSON only (no content negotiation on `Accept`).
- The public base URL of the document comes from the application's own URL configuration,
  not from the request's `Host` header.
- On the events endpoint, a `X-Qory-Contract-Version` that is sent and is not the integer `1`
  (another number, not a number, sent twice) is `400` with the versions served; absent is
  accepted. On a GET the header is still only recorded.
- The body limit is 2 MiB, twice the mebibyte a runner cuts a batch at, and it is checked
  before the signature.
- The rate limit is per access key and per node: 50 batches a second, 100 at once
  (`config :apiary, Apiary.Runs.RateLimit, rate: 50, burst: 100`). Every request that passed
  the `413`, the `401` and the `415` spends a token, whatever it is answered after that: a
  `400` and a `410` count like a `202`, so a key that keeps sending what is refused is slowed
  like any other. What is refused before, and so an unauthenticated request, spends nothing.
- A batch holds at most 1000 events, `data` nests at most 64 levels, `time` is in the years
  1970 to 9999, and `sequence` starts at `0000000001`; anything else is `400`
  `invalid_batch`.
- Events are stored as received and unknown types are kept. The one exception: a NUL
  character inside `data`, which Postgres cannot hold, is stored as U+FFFD; a `type` with one
  is not a batch.
- `time` may carry any RFC 3339 offset and is stored in UTC, to the microsecond.
- `X-Qory-Delivery` that is absent or not a UUID does not fail the delivery: the batch is
  stored and its delivery is recorded under an id the server makes up, so such a delivery is
  deduplicated by event id only.
- `X-Qory-Timestamp`, `X-Qory-Access-Key` or `X-Qory-Signature-256` sent twice on a POST is
  `401`, though the timestamp's value is not read.
- A `POST` answers `503 {"error":"unavailable"}` when the database refuses the batch or
  cannot be reached: the transaction is rolled back, the log names the kind of the failure and
  nothing of the batch, and no `X-Qory-Configuration` is sent. A runner retries anything that
  is not `2xx` or `410`.
- The path is matched after percent-decoding, as the router matches it: `/v1/%65vents` is the
  events endpoint, signed and verified like it.
- The run configuration endpoint never answers `304`, whatever `If-None-Match` says: to a
  runner anything but `200` is no run. The `ETag` is there for a person with `curl`.
- A `forge` or a `repository` label names a repository when it is a string of valid UTF-8,
  not empty, at most 256 bytes, with no control character: C0, DEL, C1 (U+0085 among them),
  U+2028 and U+2029, anything that ends a line somewhere. A label that fails this is neither
  cleaned nor cut, since either would file the run under a repository it did not name. The
  run is kept with its labels as sent, belongs to no repository (the console lists it as
  unassigned), and is served the hive's baseline. One function decides this for the
  projector, which makes repositories from the labels of `run.started`, and for the wire, so
  the run configuration endpoint and the digest in an answer always pick the same repository
  as the projector, or none. On the endpoint the labels are compared to the stored ones byte
  for byte after the query's percent-decoding; a parameter sent as anything but one string
  (`forge[]=`) names no repository, which is the baseline and not an error. Of a parameter
  sent twice the last is read. Nothing of the query is logged.
- When the run configuration cannot be read the endpoint answers `503
  {"error":"unavailable"}`, which is no run: the run fails closed, as it does on any answer
  but `200`.
- The digests in an answer to a batch are read after the commit, never rendered: one read
  that says whether the hive's policy is managed (an index on `policy_changes`), then, for a
  managed hive, the newest configuration of the run's repository (one read of an index), and
  the baseline's after it when the repository has none of its own; while the run's
  repository is not known yet, a lookup of the repository by its labels or of the reported
  digest comes before. Three to four small reads, not one. If a read fails the header it
  decides is absent, which means nothing to a runner, and the delivery is still `202`.
- A run's repository is known to the server once its `run.started` is projected, which is
  after the receiver answers. Until then the answer's digest is, in this order: that of the
  repository the batch's own `run.started` labels name; else, when the request's
  `X-Qory-Run-Configuration` is a digest in force in the hive (the baseline's newest, or any
  repository's newest), that digest; else the baseline's. So the ping of a run that fetched
  its repository's configuration a moment ago is not answered the baseline's digest and sent
  to fetch again. A runner told a digest it does not hold fetches once and remembers the
  answer it tried, so the worst case is one fetch that changes nothing.
- The `cost_usd` of `ai.qory.session.result` is the runtime's own total for the session:
  what Claude Code prints as `total_cost_usd` in its result line, which counts the tokens of
  the subagents the session ran as well as its own. `ai.qory.session.subagent_finished`
  carries no cost. So the apiary folds a run's cost as the sum of `cost_usd` over the run's
  result events, once each (`runs.cost_usd`), and never adds anything for a subagent: a
  result whose cost already includes its subagents is counted once, and a second result in
  the same run (a second session) is a second total. A result without a cost adds nothing;
  a run whose results carried none has no cost (null), which the console reads as
  unrecorded, not as free. A value that is not a JSON number, negative or absurd (a billion
  dollars or more) is read as absent.
- What the runner's proxy does with the policy document, read from `internal/proxy`,
  `internal/policy` and `session` of the runner at the pinned ref, and what the apiary
  renders for it:
  - A connection is decided by `egress.deny` first (`Proxy.decide`), in either mode and
    with the first matching deny entry as the rule, then by `egress.allow` and the mode,
    and only a connection that was allowed is terminated and held to `egress.paths`. A
    host that is only in `paths` is denied under `enforce`. So a host held to paths is
    rendered in **both** `allow` and `paths`, always, and a denied host is never in
    `paths`: it is never reached.
  - The path rules of a host are those of the first key of `paths` that matches it
    (`terminator.rules`), and `paths` is a Go map, whose order is not fixed: with `*.example`
    and `git.example` both in `paths`, which list holds `git.example` changes from run to
    run. A `*.` key of `paths` also holds every allowed host below it, whatever that host's
    own rule says. The apiary therefore refuses, at write time and with a sentence, a `*.`
    suffix held to paths above any other allowed entry; a name held to paths under a `*.`
    suffix that is free of paths is fine and rendered.
  - `deny` beats `allow` whatever the shapes, so a deny of a host below an allowed `*.`
    suffix is said as it is: `allow: ["*.example"]`, `deny: ["tracker.example"]`. A `*.`
    deny still takes the allow entries it covers out of `allow` (the runner would deny
    those hosts by the deny anyway), so the document lists what is reachable and nothing
    else, and a policy's count of hosts allowed is the truth. The one shape the document
    cannot say is a `*.` deny with an allow below it that outranks the deny (the hive's
    unlocked `*.example`, a repository's own `api.example`): the allow wins by precedence
    and is rendered, and the deny is not written to `deny`, since an entry there would
    deny the winning host too; it still takes out the allow entries it outranks, so under
    `enforce` those hosts are denied by having no allow, and under `observe` they are
    reached and recorded with no rule (`Apiary.Policy.Resolution`). Nothing is ever
    rendered that allows more than the page shows, or denies what the page says is
    allowed.
  - A policy with `paths` or `credentials` needs a wall: without one the runner refuses to
    start the run, in either mode, and on a reload it takes the hosts held to paths out of
    `allow` and refuses a configuration that selects credentials. The apiary renders what
    the rules say; the page and the export say that paths and credentials need a wall.
  - A credential the machine does not define is no run. The apiary names credentials and
    cannot know what a machine defines.
