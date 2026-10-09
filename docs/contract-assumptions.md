# The server contract as the apiary implements it

What discovery, the events endpoint, the run configuration and enrolment expect and
return. The contract is `contracts/forager/v1` of the `qoryai/forager` repository, revision
1; this page is the apiary's reading of it, and where the two disagree the contract wins.
Anything the contract has not fixed is listed under "Assumed" at the end.

## Signed requests

Every request to discovery, the run configuration and the events endpoint names a node's
access key and is signed with its secret, an Ed25519 key the server holds the public half
of (`ApiaryWeb.Contract.SignedRequest`). The headers on every request:

| Header | Value |
|---|---|
| `X-Qory-Access-Key-Id` | the key id, `ak_` and 16 lowercase Crockford base32 characters |
| `X-Qory-Instance-Id` | the instance id, `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` |
| `X-Qory-Instance-Name` | the instance's display name, unsigned, kept for display |
| `X-Qory-Contract-Version` | `1`, the revision Forager sends on every request |
| `X-Qory-Signature-Ed25519` | the Ed25519 signature of the request string, 64 bytes in base64url without padding |
| `User-Agent` | `qory-forager/<version>`; the version is recorded on the key |

A GET carries `X-Qory-Timestamp` beside them, the Unix time in seconds, UTC, as a decimal
integer with no fraction.

The request string is six lines joined by `\n` with no trailing newline
(`Apiary.Contract.SignedMessage.request/5`):

```
qory-request-ed25519-v1
ak_f1xt0re000000000
i_gYKDhIWGh4iJiouMjY6PkA
GET
/.well-known/qory-configuration?x=1
1700000000
```

1. `qory-request-ed25519-v1`;
2. the access key id, exactly as its header carries it;
3. the instance id, exactly as its header carries it, or an empty line when it is absent;
4. the method, upper case;
5. the request target: the path, followed by `?` and the query string only when the query
   string is non-empty, both exactly as sent on the wire (no decoding, no re-ordering, no
   trailing slash added or removed);
6. for a GET the value of `X-Qory-Timestamp` as sent, for a POST the raw request body.

The known answers are the contract's `fixtures/known-answers/signatures.json`, under the
fixture key `ak_f1xt0re000000000` (`fixtures/known-answers/keys.json`), and the contract's
`fixtures/signed/*` are replayed against the endpoints with the status each must get. The
signature is verified cofactorless, as RFC 8032 defines it (`Apiary.Contract.Ed25519`).

A GET's timestamp is accepted when `|server now - timestamp| <= 300` seconds. A request
that verifies but whose `X-Qory-Contract-Version` is not `1`, absent or sent twice
included, is `400` with `{"error":"unsupported_contract_version","supported":[1]}` on
every endpoint, discovery and the run configuration as the events endpoint; nothing is
served. One check decides it for the three (`ApiaryWeb.Contract.ContractVersion`), after
the signature: a request that does not verify is `401` whatever the header says.

A request that verifies records its instance as seen on the key's node
(`Apiary.Nodes.seen/3`), with its name, the Forager version and the contract version, once
the instance id passes and, on a GET, only when its timestamp is within the window: a GET
outside it, stale or replayed after the window closes, records nothing before its `401`.

**Signed answers.** Every answer to a request that verified is signed with the server's
own Ed25519 key, the key every machine pins as `apiary_public_key`
(`ApiaryWeb.Contract.SignedAnswer`, `Apiary.SigningKey`), whatever its status but `401`:
`X-Qory-Signature-Ed25519` over six lines (`Apiary.Contract.SignedMessage.answer/5`),
`qory-answer-ed25519-v1`, the status, the request's `X-Qory-Signature-Ed25519` exactly as
sent, the lowercase hex SHA-256 of the body, the answer's `X-Qory-Configuration` and its
`X-Qory-Run-Configuration` (each empty when absent), with `Cache-Control: no-store,
no-transform`. A refusal after verification is coded, `application/json`,
`{"error":"<code>"}`. Every `401` goes out unsigned, and so does a refusal before
verification: the `413`, the `415` and the `400` of a header sent twice. An answer to an
enrolment is signed under its own first line, `qory-enrol-answer-ed25519-v1`
(`Apiary.Contract.SignedMessage.enrolment_answer/3`), with the request's `proof` as line 3
and lines 5 and 6 empty, so it never verifies as the answer to a signed request, nor the
reverse (see "Enrolment"). The server's key
comes from `APIARY_SIGNING_SECRET`, which is refused at boot when it is one of the
contract's fixture seeds.

## The discovery document

`GET /.well-known/qory-configuration`, signed as above, answers `200` with
`Content-Type: application/json` and the header `X-Qory-Configuration: sha256=<lowercase hex>`,
the SHA-256 of the body as sent, or `400 unsupported_contract_version` to a contract version
other than `1`:

```json
{
  "version": 1,
  "node_id": "nd_f1xt0re000000000",
  "events": {"url": "https://<public host>/v1/events", "types": ["*"]},
  "run": {"url": "https://<public host>/v1/run-configuration"},
  "apiary_public_key": [{"alg": "ed25519", "public_key": "<the server's public key>"}]
}
```

`<public host>` is the application's public base URL (`PUBLIC_URL`). `node_id` is the
public id of the key's node or node pool. The `events` URL is the events endpoint below,
and the `run` URL the run configuration endpoint after it. `apiary_public_key` lists the
server's signing key, for information: the gateway verifies answers under the key it pinned.
The members are in the contract's order (`ApiaryWeb.Contract.Configuration`).

The `run` section is there only for a workspace whose policy somebody has made: a
workspace with a run configuration, which only a change of its policy writes, the first
rule or the first change of mode, in the workspace or in any one repository: the first
change anywhere starts serving every repository of the workspace, the others the
workspace's baseline. A
workspace nobody has given a policy is answered the document without `run`, and its
machines run under the policy of their own `forager.yaml`, as the contract has it for a
server that names no section. So an upgrade, or a workspace nobody has looked at, never
replaces a machine's own enforcement with an empty policy. The document therefore differs
by node, and for a node is one of two, by its workspace, and so is its digest, here and in
every answer to a batch. The first
change of a workspace's policy changes that digest: a run in flight fetches the document
again, finds the section, fetches its run configuration and applies it, narrowed by the
machine's own policy. It does not go back: a workspace whose rules were all
removed again still serves its (empty) policy. Sections the gateway does not know are to be
ignored.

## Signed POST: the events endpoint

`POST /v1/events`, one batch of one run's events per request, with these headers:

| Header | Value |
|---|---|
| the headers of every request | above, `X-Qory-Signature-Ed25519` over the request string whose last line is the raw body |
| `Content-Type` | `application/cloudevents-batch+json` |
| `X-Qory-Delivery` | a UUID per batch; a retry of the batch carries the same one |
| `X-Qory-Run-Configuration` | optional; the digest of the run configuration the run holds, `sha256=<hex>` |

No timestamp is signed and no window is checked; a `X-Qory-Timestamp` on a POST is not
read. The signature is verified over the bytes as received, before anything parses them,
and covers the path, so a body signed for one endpoint fails at every other.

A request is refused in this order, the order of the contract's reference receiver, and the
first refusal that applies is the answer:

| Status | When | Body |
|---|---|---|
| `413` | the body is over 2 MiB (2 097 152 bytes), or cannot be read; unsigned | `{"error":"payload_too_large"}` |
| `415` | the content type is not `application/cloudevents-batch+json` (its case and any parameters are ignored); unsigned | `{"error":"unsupported_media_type"}` |
| `400` | `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`, `X-Qory-Signature-Ed25519` or `X-Qory-Timestamp` sent twice; unsigned | `{"error":"bad_request"}` |
| `401` | any failure of authentication (see Failure); unsigned | `{"error":"unauthorized"}` |
| `429` | the key has delivered more than its rate; `Retry-After` says how many seconds to wait | `{"error":"rate_limited"}` |
| `400` | the instance id is absent or outside its pattern | `{"error":"bad_request"}` |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included | `{"error":"unsupported_contract_version","supported":[1]}` |
| `400` | the body is not a batch, is over a limit below, or holds a ping whose `interval_seconds` is absent or not an integer from 1 to 300 | `{"error":"invalid_request"}` |
| `404` | the key may not post events (`run.post_events`), as a path that does not exist | `{"error":"not_found"}` |
| `410` | the workspace has closed the run, or retention has pruned the run's events: the delivery is recorded, no event is stored | empty |
| `409` | the ping of a new run, from an instance beyond its node's instance limit (`Apiary.Nodes.admit/4`): nothing is stored | `{"error":"instance_limit"}` |
| `503` | the batch could not be stored; nothing of it was | `{"error":"unavailable"}` |
| `202` | stored | empty |

Every answer after the `401` is signed.

Every `202` and `410` carries the digests in force: `X-Qory-Configuration`, the digest the
workspace's discovery answer carries, and, for a workspace whose policy somebody has made,
`X-Qory-Run-Configuration`, the digest of the run configuration for the run's repository (see
"The run configuration" below for which that is while the repository is not known yet). A
workspace without a policy of its own is never answered the second. No other status
carries it. No error body repeats anything that was sent. The ping is a batch like any
other: a `2xx` lets the run start, and a revoked key, a bad signature, an instance beyond the
limit or an unsupported version does not.

A batch is a non-empty JSON array of at most 1000 objects (the gateway cuts a batch at a
hundred), each with `id` and `subject` (lowercase UUIDs), `type` (beginning `dev.qory.`),
`sequence` (ten digits, from `0000000001`: `0000000000` is no sequence), `source`
(`urn:qory:run:` and the subject), `time` (RFC 3339, in the years 1970 to 9999) and `data`
(an object, nested no deeper than 64 levels), all of one subject. The limits are what the
tables hold: what passes them is stored, and no batch is answered `500`. Only this envelope is
checked: `data` is not validated against the schema of its type, and a type this release does
not know is stored like any other, so a newer Forager's events are kept until a release reads
them. A type outside `dev.qory.` fails the envelope, and the batch is answered
`400 invalid_request`. A ping (`dev.qory.ping`) carries `interval_seconds`, the heartbeat
interval of its run, an integer from 1 to 300 (`Apiary.Runs.Batch`).

What is stored, in one transaction, before the answer:

- the run, created on the first event of a subject the key's workspace has not seen, in
  that workspace, in state `pending`, with the key that delivered it, the key's node and
  the instance id the request claimed (`Apiary.Nodes.placement/2`), both fixed from then
  on, and the versions the request named. A batch that would create a run with its ping
  is first admitted by the node's instance limit, under the node's row lock
  (`Apiary.Nodes.admit/4`): a node runs one instance at a time, a pool up to its limit,
  and an instance counts while one of its runs is alive. The same subject under another workspace is another run. Two first
  batches at once make one run. The run's row is locked while its batch is stored, so a
  close and a batch never cross: a close that commits first is answered `410`, and a
  closed run never gains an event;
- nothing, for a run retention has pruned. Deduplication is against the events the
  workspace holds, and a pruned run holds none, so a batch delivered again after the prune
  could not be told from a new one and would be folded a second time. The workspace
  therefore wants nothing more of a run whose events it pruned, and says so the way it
  does for a closed run: `410`, the delivery recorded, no event stored. A run that lost
  only its log output (the log's days are shorter than the events') still takes events,
  deduplicated against the ones it keeps, but no `dev.qory.run.log` event: its log events
  are gone, so a replayed one could not be recognised, and one that is new would be older
  than the workspace keeps log output. Such events are answered like duplicates, within a
  `202`. Neither case arises for a run that is alive: retention only prunes a run that has
  ended or gone silent for days;
- each event, as received: `id`, `sequence` as an integer, `type`, `time`, `data`, and when it
  was received. An event already held (the same `id`) is skipped: delivery is at least once.
  An event whose `id` is held by another run of the workspace, or whose `sequence` in its
  run is held under another `id`, is dropped and counted in a log line; it is never an
  error, since sending it again could not help. Events are read back by `sequence`, never
  by arrival;
- the delivery: the key, the instance id, `X-Qory-Delivery`, the subject, how many events it held, how many were
  new, the status answered, and the batch's `X-Qory-Run-Configuration` when it had the shape
  of a digest. A delivery id the key has delivered before is answered `202` again and nothing
  is stored;
- on the run: the count of events, when the last one was received, and the last
  `X-Qory-Run-Configuration` that had the shape `sha256=` and 64 lowercase hex digits.

After the commit, and never failing the request: the key records the time, and the Forager
version and the contract version when the request named them (a request that names none
leaves what is recorded); when the batch held a heartbeat that was new, the key records when
the server received it, by the server's clock and never Forager's. A repeated delivery
records nothing on the key. The run's events are projected into the run, its connections and its log, on the server's own
time. Nothing of a request's headers beyond the above is stored, and neither the signature nor
the body is logged.

## Signed GET: the run configuration

`GET /v1/run-configuration?<label>=<value>&…`, signed like discovery, the query signed as
sent. Every query parameter is read as one of the run's labels, and the gateway sends every
label of the run. The workspace's domain (`Apiary.Lingo.Domain`) says which labels name
the target; the software domain's are `forge` and `repository`. It answers `200`,
`Content-Type: application/json`, with `X-Qory-Run-Configuration: sha256=<lowercase hex>`,
`ETag: "sha256=<hex>"` (the same string, quoted), `X-Qory-Configuration` and
`Cache-Control: no-store, no-transform`, signed like every answer to a verified request:

```json
{"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["api.example"]}}}
```

With deny rules the `egress` section carries `deny` after `allow`, the hosts the gateway denies
before it consults `allow` or the mode:

```json
{"version":1,"security_policy":{"version":1,"egress":{"mode":"observe","allow":["*.example"],"deny":["tracker.example"]}}}
```

The body is the bytes that were stored when the policy was last changed; nothing is rendered
for a request, so the digest is of exactly what is sent. It is the configuration of the
key's workspace for the repository the two labels name. A repository the workspace has not
seen, one with neither rules nor a mode of its own, and a request that names none (or one
label of the two) get the workspace's baseline. `egress.mode` is the workspace's, unless
the repository has set its own, `observe` or `enforce`; a repository that has not follows
the workspace, later changes of the workspace's mode included, and a repository the
workspace has not seen gets the workspace's. The rules resolve the same under either mode:
a locked rule of the workspace holds in a repository's document whatever its mode, and a
deny holds in either mode, since `egress.deny` is decided first: under `observe` the gateway
denies what `deny` names and nothing else, and `allow` says what `enforce` would reach. A
workspace whose policy nobody has made serves none: `404` `{"error":"not_found"}`, nothing
rendered; discovery named it no `run` section, so the gateway does not ask. The endpoint
spends a token of the key's rate limit, the events endpoint's bucket:
`429 {"error":"rate_limited"}` with `Retry-After` beyond it, which to the gateway is no run
or a reload that failed and is tried again on the next answer. After the `429`, as on the
events endpoint, a contract version other than `1` is `400 unsupported_contract_version`,
and nothing is read.

Rendering is canonical: members in a fixed order (`mode`, `allow`, `deny`, `paths`), no
whitespace, `allow` and `deny` sorted with names before `*.` suffixes (so the rule the gateway
reports for a connection is the most exact one), `paths` by host with each list sorted;
`allow` is always present, `deny` and `paths` only when they hold something, so a policy
without a deny renders the bytes it always did. The document never has `credentials`: the
contract's policy may select credentials of the machine's, and this one selects none. The
same rules give the same bytes and the same digest, a change that renders the same bytes makes no new version, and every
document is validated against the contract's `run-configuration.schema.json` and
`policy.schema.json` (vendored under `priv/contract/`) before it is stored: a change whose
render the schema refuses is not made, and neither is one whose render is over 1 MiB, the
most the gateway reads of a document (`MaxDocument`). A list holds at most 500 rules and a rule
at most 100 paths.

## Enrolment

`POST /.well-known/qory-enrolment` (`ApiaryWeb.Contract.EnrolmentController`): a machine
enrols a new access key with an enrolment code made on a node, by the contract's
`enrolment.schema.json`. No access key id and no request signature: the code and the
proof authenticate it. Nothing is signed until the code is accepted, the key passes the key
checks and the proof verifies under it. The answers, in order:

| Status | Signed | When |
|---|---|---|
| `413` | no | a body over 8 KiB |
| `415` `unsupported_media_type` | no | a `Content-Type` absent, or one of its values not `application/json` (any case, parameters allowed) |
| `400` `bad_request` | no | `Content-Type` or `X-Qory-Contract-Version` sent twice |
| `429` `rate_limited` | no | over the limit of the address it came from, with `Retry-After` |
| `400` `unsupported_contract_version` | no | `X-Qory-Contract-Version` absent or not `1` |
| `400` `invalid_request` | no | a body the schema refuses, naming the members at fault: a member unknown or twice, a code not in its normal form, a timestamp with a fraction or an exponent |
| `401` `unauthorized` | no | the code is used, expired, cancelled or unknown, carries another fingerprint than the instance's key's, or was made by someone who is no longer an owner or an admin of its workspace; or the timestamp is more than 300 seconds from the server's clock |
| `409` `key_invalid` | no | the key checks refuse the key (`Apiary.Contract.Ed25519.decode_public_key/1`: a canonical encoding, on the curve, y ≠ 1, not of small order, of prime order, not a published fixture key), checked first, or the proof does not verify under it |
| `429` `rate_limited` | yes | over the code's own limit, with `Retry-After` |
| `409` `key_invalid` | yes | the ledger holds the key: another access key's, a revoked one included |
| `409` `key_limit` | yes | the node holds two keys |
| `201` | yes | the key is made, and active |

A signed answer is signed under `qory-enrol-answer-ed25519-v1`; its line 3 is the request's
`proof`, and its body lists `apiary_public_key`. The `201` carries `version`,
`access_key_id`, `node_id`, `node_kind`, `stored_secrets` and `apiary_public_key`. An
unsigned answer lists no key. A refusal changes nothing: the code stays outstanding.

## The log and the terminal

`dev.qory.run.log` is stored like any event and its bytes, decoded, are the run's
`log_chunks`, one row a chunk, keyed by the event's sequence; `output.log` is their
concatenation in sequence order, which is what the log endpoint of the console streams. How
the session cuts the chunks is its own affair and the apiary reads nothing into a boundary:
on pipes a chunk is one line or 4096 bytes and may end inside a multibyte character, on a
pseudo-terminal it is one redraw, 4096 bytes or a quiet gap of 50 ms after the runtime's
last write, never inside a character. The terminal of the run page hands the bytes to
xterm.js as bytes, so a character cut in two is still one character.

The size of the pseudo-terminal is in the record: `terminal` of `dev.qory.run.started`
(`cols`, `rows`, present exactly when `interactive` is true) and one `dev.qory.run.resized`
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

A run without a size is a run on pipes: the endpoint sends no size header and the page fits
the screen to the box, with the wrap toggle. On pipes `stream` is `stdout` or `stderr`, never
`terminal`, and a single stream of a pipes run, or a download, is never sized.

## What opened a run

`dev.qory.run.started` says what opened the run, in `opened_by`, which the contract
requires:

- `session`: a Forager session around a runtime. The event carries the runtime, the
  command, its arguments, the directory and whether it is interactive, with the host, the
  terminal's size, the wall and the image where they apply, and the run's
  `dev.qory.run.exited` carries `state` and `exit_code`.
- `gateway`: a gateway opened the run for a program that reports no session. The run has
  no process, so the event carries none of `runtime`, `runtime_version`, `command`,
  `args`, `dir`, `interactive`, `terminal`, `host`, `wall` and `image`, and the run's
  `dev.qory.run.exited` carries neither `state` nor `exit_code`. It still carries
  `forager_version`, the gateway's own, its labels, `run_key` among them, and
  `about.details`, as the gateway gives them.

The run keeps `opened_by`, and a run a gateway opened is shown as a run with no session:
no runtime, no host, no command and no exit code, since the record holds none
([ui.md](ui.md), The run page).

A run through a separate gateway belongs to the gateway's node, instance and key, since
the gateway is the node toward the server: it sends the ping and delivers every event of
the run under its own access key. The machines behind it hold no access key. For a
session's run through it, `host` is the agent's machine, the one the runtime runs on, so
the run's Node is the gateway's and its Host the agent's machine.

## How a run ends

`dev.qory.run.exited` carries `reason` when the run ended other than by the runtime's own
exit, one of seven:

| `reason` | What Qory saw | Words | State without `state` |
|---|---|---|---|
| `timeout` | the run reached its time limit | timed out | Timed out (`timed_out`) |
| `run_closed` | the server closed the run | closed | Closed (`closed`) |
| `gateway_lost` | the gateway was lost before the run's end was recorded | gateway lost | Failed (`failed`) |
| `session_lost` | the gateway lost the session: it heard nothing from it for three of its heartbeat intervals, or refused its events | session lost | Failed (`failed`) |
| `quiet` | a run with no session had no connection for the gateway's quiet period | quiet for N minutes | Ended (`ended`) |
| `credential_expired` | the run credential expired | run credential expired | Ended (`ended`) |
| `run_ended_at_issuer` | the issuer reported the run ended | the issuer reported the run ended | Ended (`ended`) |

`quiet_seconds`, an integer of at least 1, comes with `quiet` and with no other reason:
the quiet period the gateway applied, which the words say as a duration reads: 1800
seconds is "quiet for 30 minutes". The words follow the state in the run page's meta line
and stand under State in its Details rail.

`state` and `exit_code` are optional. A session's run carries both, `failed` and `-1`
with `gateway_lost` and `session_lost`; a run a gateway opened carries neither, whatever
its reason. When `state` is there it decides as it always has: `succeeded` is Succeeded,
`failed` with `timeout` is Timed out, and any other `failed` is Failed. When it is not,
the reason decides, by the last column above; the contract fixes no state per reason and
leaves each receiver its own. Ended is a state of its own: the run ended, and nothing
checked an outcome. It counts with the runs that ended well, never with those that ended
badly. A run the workspace closed stays Closed whatever its `dev.qory.run.exited` says.

## Liveness

A run is alive from its first event until its `dev.qory.run.exited`, until the workspace
closes it, or until it goes silent. Qory Apiary's own lost-run check
(`Apiary.Runs.Liveness`) marks a run `lost` when nothing has been heard of it for more than
three of the heartbeat intervals it announced (`interval_seconds`, which its ping and its
heartbeats carry), 90 seconds when it announced none: a `running` run from its last
heartbeat, else from the arrival of its `run.started`, and a `pending` run from when the
workspace first heard of it. Only the server's clock is compared.

Every event of a run reaches the server from one gateway, the node toward the server: a
session's heartbeats through it, and a run with no session the gateway's own. So `lost`
means the gateway stopped sending for the run. A session that falls silent is the
gateway's to notice, and it ends the run with `session_lost`, which the server sees as an
exit. `lost` is not final: a later heartbeat or the run's `dev.qory.run.exited`, such as
the `gateway_lost` a gateway sends when it starts again, corrects the state.

## Failure

Every failure of authentication is `401` with the body `{"error":"unauthorized"}` and
nothing else, unsigned, whether the cause is a missing or empty `X-Qory-Access-Key-Id` or
`X-Qory-Signature-Ed25519`, a key id that is not of the exact form `ak_` and 16 lowercase
Crockford base32 characters (including one that is not valid UTF-8; such a value is refused
before any lookup), a key id that does not exist, a revoked key, a key of a node that was
deleted, a key whose row does not match its integrity code, a signature that is not 64
bytes of base64url or does not verify, or, on a GET only and after the version's `400`, a
timestamp that is not an integer or is outside the window. The body
never says which. A request under a key id the server does not hold is verified under a
fixed public key all the same, so that it costs what a known one does. Nothing about the
request's headers is logged.

On a GET that verifies, the key records the time, the Forager version from `User-Agent` (when
it is of the form `qory-forager/<version>`) and the contract version from
`X-Qory-Contract-Version` when it is `1`; a request with any other is refused and leaves the
recorded contract version as it is. The Forager version never decides the answer:

- the Forager version is kept to its first 80 characters; a `User-Agent` that is not valid
  UTF-8, or a version with non-printable characters, records no version;
- if recording the use fails, the request still succeeds.

No header value makes the endpoint answer `500`.

## Assumed

The contract has not fixed these; Qory Apiary chose, and Forager should match:

- The signature is decoded strictly: base64url without padding, 86 characters for 64
  bytes. Padding, the standard alphabet or another length is `401`, like a signature that
  does not verify.
- The query string joins the path with `?` only when non-empty, so `/path` and `/path?`
  sign differently.
- `X-Qory-Instance-Name` is kept as the instance's display name and decides nothing; the
  instance id is a signed line, and authorisation rests on the access key alone.
- `User-Agent` that is not `qory-forager/<version>` is accepted; only the recorded Forager
  version is left empty. The same holds for a version that is not printable text, and a
  version longer than 80 characters is recorded truncated.
- The discovery path is `/.well-known/qory-configuration`, without a trailing slash, and
  answers JSON only (no content negotiation on `Accept`).
- The public base URL of the document comes from the application's own URL configuration,
  not from the request's `Host` header.
- On every signed endpoint, a `X-Qory-Contract-Version` that is not the integer `1`
  (absent, another number, not a number, sent twice) is `400` with the versions served,
  once the request has verified, after the `429` and the instance id's `400`. At
  enrolment the header is read before the code, unsigned: sent twice it is `400`
  `bad_request`, and any other value that is not `1` is `400` with the versions served,
  after the per-address `429`.
- The body limit is 2 MiB, twice the mebibyte the gateway cuts a batch at, and it is checked
  before the signature.
- The rate limit is per access key and per node: 50 batches a second, 100 at once
  (`config :apiary, Apiary.Runs.RateLimit, rate: 50, burst: 100`). Every request that passed
  the `413`, the `415`, the `400` of a header sent twice and the `401` spends a token,
  whatever it is answered after that: a `400`, a `409` and a `410` count like a `202`, so a
  key that keeps sending what is refused is slowed like any other. What is refused before,
  and so an unauthenticated request, spends nothing. Discovery spends none.
- A batch holds at most 1000 events, `data` nests at most 64 levels, `time` is in the years
  1970 to 9999, and `sequence` starts at `0000000001`; anything else is `400`
  `invalid_request`.
- Events are stored as received and unknown types are kept. The one exception: a NUL
  character inside `data`, which Postgres cannot hold, is stored as U+FFFD; a `type` with one
  is not a batch.
- `time` may carry any RFC 3339 offset and is stored in UTC, to the microsecond.
- `X-Qory-Delivery` that is absent or not a UUID does not fail the delivery: the batch is
  stored and its delivery is recorded under an id the server makes up, so such a delivery is
  deduplicated by event id only.
- `X-Qory-Timestamp` sent twice on a POST is `400` `bad_request`, as on a GET, though a
  POST's timestamp is not read.
- A `POST` answers `503 {"error":"unavailable"}` when the database refuses the batch or
  cannot be reached: the transaction is rolled back, the log names the kind of the failure and
  nothing of the batch, and no `X-Qory-Configuration` is sent. The gateway retries anything that
  is not `2xx` or `410`.
- The path is matched after percent-decoding, as the router matches it: `/v1/%65vents` is the
  events endpoint, signed and verified like it.
- The run configuration endpoint never answers `304`, whatever `If-None-Match` says: to the
  gateway anything but `200` is no run. The `ETag` is there for a person with `curl`.
- A `forge` or a `repository` label names a repository when it is a string of valid UTF-8,
  not empty, at most 256 bytes, with no control character: C0, DEL, C1 (U+0085 among them),
  U+2028 and U+2029, anything that ends a line somewhere. A label that fails this is neither
  cleaned nor cut, since either would file the run under a repository it did not name. The
  run is kept with its labels as sent, belongs to no repository (the console lists it as
  unassigned), and is served the workspace's baseline. One function decides this for the
  projector, which makes repositories from the labels of `run.started`, and for the wire, so
  the run configuration endpoint and the digest in an answer always pick the same repository
  as the projector, or none. On the endpoint the labels are compared to the stored ones byte
  for byte after the query's percent-decoding; a parameter sent as anything but one string
  (`forge[]=`) names no repository, which is the baseline and not an error. Of a parameter
  sent twice the last is read. Nothing of the query is logged.
- The run's other labels are kept as sent. A `task` label is an ordinary label, shown
  under Labels with the others; it neither titles nor filters a run.
- What a run is about is `about` of `dev.qory.run.started`, optional, read member by member
  (`Apiary.Runs.Fold`). No string of it, key or value, may hold a control character (U+0000
  to U+001F, U+007F to U+009F, U+2028, U+2029). `kind` (1 to 64 bytes), `title` (1 to 256
  bytes) and `details` are each kept whole or dropped whole when they break a rule.
  `details` is a JSON object of at most 8192 bytes as the event carries it (compact, with
  `<`, `>` and `&` written as `\u003c`, `\u003e` and `\u0026`), at most 4 levels deep
  (`details` itself the first, an array a level like an object), each key at any level 1 to
  64 bytes; one bad key or string anywhere drops it whole. A member name given twice in
  `details` cannot be seen once the event is decoded, which keeps the last: Forager
  refuses it. `subjects` is a list of `{type, ref, url?, title?}`: a subject whose `type`
  does not match `^[a-z0-9]+([ _.-][a-z0-9]+)*$` in at most 64 bytes, or whose `ref` is not
  1 to 256 bytes, is dropped on its own; its `title` (1 to 256 bytes) and `url` (at most
  2048 bytes) are dropped from it alone when they break theirs. A `url` is kept only when it
  is absolute `http` or `https` with a host and no user name or password. Subjects are
  de-duplicated by type and ref, the first kept, and more than 16 are cut to the first 16.
  Forager refuses a run whose `about` breaks any of these; the fold drops the part that
  breaks one, for whatever reaches it. A type is shown as given: Qory Apiary knows no
  subject types. A later `run.started` replaces all of it, like every other field. A run's
  title is its `about` title; without one, the run page says `Run` and its short id, the
  lists the short id, and the Overview its command line, else its short id. Nothing of
  `about` is part of the run configuration request, which carries the labels alone, so it
  never decides a run's policy.
- When the run configuration cannot be read the endpoint answers `503
  {"error":"unavailable"}`, which is no run: the run fails closed, as it does on any answer
  but `200`.
- The digests in an answer to a batch are read after the commit, never rendered: one read
  that says whether the workspace's policy is managed (an index on `run_configurations`),
  then, for a managed workspace, the newest configuration of the run's repository (one
  read of an index), and the baseline's after it when the repository has none of its own;
  while the run's repository is not known yet, a lookup of the repository by its labels or
  of the reported digest comes before. Three to four small reads, not one. If a read fails
  the header it decides is absent, which means nothing to the gateway, and the delivery is
  still `202`.
- A run's repository is known to the server once its `run.started` is projected, which is
  after the receiver answers. Until then the answer's digest is, in this order: that of the
  repository the batch's own `run.started` labels name; else, when the request's
  `X-Qory-Run-Configuration` is a digest in force in the workspace (the baseline's newest,
  or any repository's newest), that digest; else the baseline's. So the ping of a run that
  fetched its repository's configuration a moment ago is not answered the baseline's
  digest and sent to fetch again. A gateway told a digest it does not hold fetches once and
  remembers the answer it tried, so the worst case is one fetch that changes nothing.
- The `cost_usd` of `dev.qory.session.result` is the runtime's own total for the session:
  what Claude Code prints as `total_cost_usd` in its result line, which counts the tokens of
  the subagents the session ran as well as its own. `dev.qory.session.subagent_finished`
  carries no cost. So the apiary folds a run's cost as the sum of `cost_usd` over the run's
  result events, once each (`runs.cost_usd`), and never adds anything for a subagent: a
  result whose cost already includes its subagents is counted once, and a second result in
  the same run (a second session) is a second total. A result without a cost adds nothing;
  a run whose results carried none has no cost (null), which the console reads as
  unrecorded, not as free. A value that is not a JSON number, negative or absurd (a billion
  dollars or more) is read as absent.
- Tool invocations are read by the same pipeline as any egress: a `dev.qory.run.egress`
  with `tool` is a connection keyed like any request, by host, port and path, and the
  tool is not part of the key, since the contract refuses a host two tools serve. The
  projection keeps the last attempt's `tool` (a non-empty string, cut at 255 bytes) and
  `status` (an integer from 100 to 599; anything else is absent) in `connections.last_tool`
  and `last_status`, last by sequence like the other `last_*` columns: an attempt without
  `tool` clears it. Only a request decided on its path names its tool; a connection
  refused on its host (deny list, the wall's guard, the allow list) carries none and is a
  plain connection. A request a path rule refused names its tool as well, and never
  reached it: a tool invocation is an egress event that names a `tool` and whose
  `decision` is `allowed`, and nothing else (`Apiary.Runs.tool_invocation?/2`, and its
  SQL twin on `last_tool` and `last_decision`). The fold keeps the tool of a refused
  request as of any other, and the pages read the decision with it. The fold reads
  `tool` and `status` from any egress event that carries them. `request_id` is not projected: the timeline reads it from the event, where one
  request is shown. The `tools` of `dev.qory.run.policy_applied` are read like its
  `credentials`: twenty at most, each with ten hosts at most. A credential use and a tool
  may contain `argument`, the argument the policy passed to it (up to 4096 code points in
  the contract). The policy in force on a run's Details tab reads it whole, cut only past
  4096 code points; the timeline's policy applied item reads a tool's cut at 256
  (`Apiary.Runs.Record.Timeline.max_argument/0`), and its one-line summary shows the first 64 of them, with the 256 in the argument's title. A
  cut argument ends in `…`. Lengths are code points, as the schemas' `maxLength` and the
  database's `left` count them, in the query and in `Timeline.slim/1` alike. The event
  lists each use of a credential, all with the same name and argument; the Details tab
  shows them as one entry with the hosts of every use. It reads the first twenty uses and
  the first twenty tools, and counts the different names and arguments among all of them,
  so "and N more" is the number of entries, grouped, that it does not show. The vendored
  policy schema at the pinned ref also lets a policy select `tools` and an `image`, which
  the apiary does not render; the tests of tool invocations and of arguments use fixtures
  of their own beside the contract's.
- What the gateway does with the policy document, read from `gateway/internal/proxy`,
  `policy` and `session` of Forager at the pinned ref, and what the apiary
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
    deny still takes the allow entries it covers out of `allow` (the gateway would deny
    those hosts by the deny anyway), so the document lists what is reachable and nothing
    else, and a policy's count of hosts allowed is the truth. The one shape the document
    cannot say is a `*.` deny with an allow below it that outranks the deny (the workspace's
    unlocked `*.example`, a repository's own `api.example`): the allow wins by precedence
    and is rendered, and the deny is not written to `deny`, since an entry there would
    deny the winning host too; it still takes out the allow entries it outranks, so under
    `enforce` those hosts are denied by having no allow, and under `observe` they are
    reached and recorded with no rule (`Apiary.Policy.Resolution`). Nothing is ever
    rendered that allows more than the page shows, or denies what the page says is
    allowed.
  - A policy with `paths` or `credentials` needs a wall: without one Forager refuses to
    start the run, in either mode, and on a reload it takes the hosts held to paths out of
    `allow` and refuses a configuration that selects credentials. The apiary renders what
    the rules say and selects no credential; the page and the export say that paths need
    a wall.
- Enrolment: the same code posted again with the same public key, a proof that verifies and
  a fresh timestamp, while the code's 15 minutes last and the key is not revoked, is the
  same `201` for the same key, as it is now, once within the code's limit; the contract
  says a used code is `401`, and says nothing of a repeat. Any other key on a used code is
  `401`.
- Enrolment: the published fixture keys are among the key checks, so a fixture key is the
  unsigned `409` `key_invalid`; the contract has every side refuse them, and names no step.
- Enrolment: the instance's key does not rotate, so a code it issues carries one
  fingerprint; a code that carries two, or another, is `401`.
- Enrolment: the key's label is the code's label hint, else the name the machine sent,
  with `-2`, `-3` and on when a key of the node in use has it already.
- Enrolment: the contract names no content type for the request; Forager sends
  `application/json`, so that is the one accepted: the media type, whatever its case and
  whatever parameters follow, in each value sent. The contract's `400` `bad_request` for "a header
  sent twice" names no headers at enrolment, and the four it names for a signed request are
  not in one; the headers counted are the two the enrolment reads, `Content-Type` and
  `X-Qory-Contract-Version`, so a header a proxy repeats, such as `X-Forwarded-For`, is no
  refusal. A `Content-Type` sent twice, each `application/json`, is that `400`; with one
  value of another type it is the `415` before it.
- Enrolment: the rate limit is per address, 1 a second and 10 at once
  (`config :apiary, ApiaryWeb.Contract.EnrolmentController, rate: 1, burst: 10`), counted
  once the content type and the headers pass, before the version or the body is looked at,
  so a request refused at `413`, `415` or a header sent twice spends none of it; the
  contract does not mention `Retry-After`, which the `429` carries all the same; and per
  code, 1 a second and 5 at once (`code_rate`, `code_burst`), counted only once the code
  is accepted and the key proven, so a refused code or an unproven key spends none of it. The contract fixes the order, not the numbers.
