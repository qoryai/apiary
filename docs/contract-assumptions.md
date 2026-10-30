# The server contract as Qory Apiary implements it

What discovery, a run's registration and reload, the events endpoint and enrolment expect
and return. The contract is `contracts/forager/v1` of the `qoryai/forager` repository, revision
1; this page is Qory Apiary's reading of it, and where the two disagree the contract wins.
Anything the contract has not fixed is listed under "Assumed" at the end.

## Signed requests

Every request to discovery, the run endpoint and the events endpoint names a node's
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
integer with no fraction. A run's registration carries its `time` in its signed body
instead (The run endpoint, below).

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

A GET's timestamp is accepted when `|server now - timestamp| <= 300` seconds, and so is a
registration's `time`. A request that verifies but whose `X-Qory-Contract-Version` is not
`1`, absent or sent twice included, is `400` with
`{"error":"unsupported_contract_version","supported":[1]}` on every endpoint, discovery and
the run endpoint as the events endpoint; nothing is served. One check decides it for the three (`ApiaryWeb.Contract.ContractVersion`), after
the signature: a request that does not verify is `401` whatever the header says.

A request that verifies records its instance as seen on the key's node
(`Apiary.Nodes.seen/3`), with its name, the Forager version and the contract version, once
the instance id passes and, on a GET, only when its timestamp is within the window: a GET
outside it, stale or replayed after the window closes, records nothing before its `401`.

**Signed answers.** Every answer to a request that verified is signed with the server's
Ed25519 key, the key every machine pins as `apiary_public_key`
(`ApiaryWeb.Contract.SignedAnswer`, `Apiary.SigningKey`), whatever its status but `401`:
`X-Qory-Signature-Ed25519` over six lines (`Apiary.Contract.SignedMessage.answer/5`),
`qory-answer-ed25519-v1`, the status, the request's `X-Qory-Signature-Ed25519` exactly as
sent, the lowercase hex SHA-256 of the body, the answer's `X-Qory-Configuration` and its
`X-Qory-Run-Configuration` (each empty when absent), with `Cache-Control: no-store,
no-transform`. A refusal after verification is coded, `application/json`,
`{"error":"<code>"}`. Every `401` goes out unsigned, and so does a refusal before
verification: the `413`, the `415` and the `400` of a header sent twice. An answer to an
enrolment is signed under a separate first line, `qory-enrol-answer-ed25519-v1`
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
  "workspaces": ["ws_f1xt0re000000000"],
  "events": {"url": "https://<public host>/v1/events", "types": ["*"]},
  "run": {"url": "https://<public host>/v1/runs"},
  "apiary_public_key": [{"alg": "ed25519", "public_key": "<the server's public key>"}]
}
```

`<public host>` is the application's public base URL (`PUBLIC_URL`). `node_id` is the
public id of the key's node, node pool or gateway (`ng_`). For a node or a node pool,
`workspaces` holds exactly one id, the public id of the workspace it belongs to
(`workspaces.public_id`, `ws_` and 16 characters, `Apiary.Organisations.Workspace`). A
gateway's document, whether the gateway is a workspace's or an organisation's, lists no
workspaces: which workspaces a gateway serves follows from the nodes that use it, and
Qory Apiary decides at each registration and attach whether it may serve the run's
workspace (`Apiary.Gateways.may_serve?/2`). Discovery has no
member naming the kind: the prefix of `node_id` says it. The `events` URL is the events endpoint below,
and the `run` URL the run endpoint after it, with no trailing slash, no query and no
fragment: a reload appends `/` and the run's id. `apiary_public_key` lists the
server's signing key, for information: the gateway verifies answers under the key it pinned.
The members are in the contract's order (`ApiaryWeb.Contract.Configuration`).

The `run` section is always there, so the document differs by node and, for a node or a
node pool, by workspace, never by the workspace's policy, and so does its digest, here and
in every answer to a batch. A gateway's digest changes only when the members it has
change.
Whether a workspace has a policy shows in the answer to a run's registration instead (The
run endpoint, below). A
workspace nobody has given a policy answers every registration `{"version":1}`, no policy,
and its machines run under the policy of their `forager.yaml`, as the contract has it
for a server with no policy. So an upgrade, or a workspace nobody has looked at, never
replaces a machine's local enforcement with an empty policy. A workspace has a policy once
somebody makes it, by the first rule or the first change of mode, in the workspace or in
any one target: the first change anywhere starts serving every target of the
workspace, the others the workspace's baseline. From that change the answers to a run's
batches carry `X-Qory-Run-Configuration`: a run in flight that was registered with no
policy holds another digest, reloads its run configuration and applies it, narrowed by the
machine's local policy. It does not go back: a workspace whose rules were all removed again
still serves its (empty) policy. Sections the gateway does not know are to be ignored.

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
| `415` | the media type is not `application/cloudevents-batch+json`, compared exactly (its case and any parameters are ignored, so `application/cloudevents-batch+jsonx` is refused); unsigned | `{"error":"unsupported_media_type"}` |
| `400` | `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`, `X-Qory-Signature-Ed25519` or `X-Qory-Timestamp` sent twice; unsigned | `{"error":"bad_request"}` |
| `401` | any failure of authentication (see Failure); unsigned | `{"error":"unauthorized"}` |
| `429` | the key has delivered more than its rate; `Retry-After` says how many seconds to wait | `{"error":"rate_limited"}` |
| `400` | the instance id is absent or outside its pattern | `{"error":"bad_request"}` |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included | `{"error":"unsupported_contract_version","supported":[1]}` |
| `400` | the body is not a batch, is over a limit below, holds `dev.qory.ping` or `dev.qory.run.registered`, or a `dev.qory.run.started` whose `opened_by` is absent or not `run`, or that carries `credential` | `{"error":"invalid_request"}` |
| `404` | the key may not post events (`run.post_events`), as a path that does not exist | `{"error":"not_found"}` |
| `409` | the subject is the `run_id` of a run of a workspace's queue, on the whole instance, in any state, and the key reaches no run under it: before the claim no key does; after it, a key reaches the run when it is a key of the run's workspace, or a gateway's that may serve the run's workspace (`Apiary.Gateways.may_serve?/2`), and keeps the answer it had. Such a run is opened only by its claim (A run of the queue, under The run endpoint); refused whole, and nothing of it, the delivery included, is stored | `{"error":"run_id_used"}` |
| `409` | the run is bound to another node than the key's (`Apiary.Runs.Sender`): a batch is one run's, so the whole batch is refused, and nothing of it, the delivery included, is stored | `{"error":"wrong_node"}` |
| `409` | the run goes through a gateway and the key is not one of the gateway's that attached it, or the instance id is not the one that attached it while the run's sending has not ended, or the key is a gateway's and the run is not one it attached; refused whole, as above | `{"error":"wrong_gateway"}` |
| `401` | the run goes through a gateway and the run's workspace or organisation is out of use, as a key of it would be; unsigned | `{"error":"unauthorized"}` |
| `404` | the run goes through a gateway and `Apiary.Access` does not let the run's workspace post (`run.post_events`), as a path that does not exist | `{"error":"not_found"}` |
| `410` | the run goes through a gateway and the gateway that attached it may no longer serve the run's workspace (`Apiary.Runs.Sender.serves?/2`, `Apiary.Gateways.may_serve?/2`), decided as at the attach; before deduplication, so a delivery already recorded is refused too; no digest header, nothing of the batch, the delivery included, is stored, and the run goes lost by liveness | `{"error":"workspace_not_served"}` |
| `410` | retention has pruned the run's events: the delivery is recorded, no event is stored | empty |
| `503` | the batch could not be stored; nothing of it was | `{"error":"unavailable"}` |
| `202` | stored | empty, or the run's `end` (below) |

Every answer after the `401` is signed.

Every `202`, and the `410` of a run whose events were pruned, carries the digests in force: `X-Qory-Configuration`, the digest the
workspace's discovery answer carries, and, for a workspace whose policy somebody has made,
`X-Qory-Run-Configuration`, the digest of the run configuration for the target the
run registered with, composed for the run as its reload is (The image, under The run
endpoint) (see "Assumed" for a run that did not register). A workspace nobody has
given a policy is never answered the second. No other status carries it. No error body
repeats anything that was sent.

A run is bound to one node: the node or node pool whose key registered it, or whose key's
batch opened it (`runs.node_id`). Its batches, a heartbeat's among them, are taken from
that node's active keys alone, whichever of them signs, so a second key of the node, while
one is replaced, keeps the run going (`Apiary.Runs.Sender`). The binding is to the node,
never to the key that registered it: once that key is revoked it verifies under no key,
`401`, and a second active key of the node carries the run on. A key of another node or
node pool of the workspace, a gateway's included, is `409 wrong_node` for a batch and
`404` for a reload or an outcome.

A run through a gateway (The run endpoint, below) takes its batches from the active keys
of the gateway that attached it (`runs.gateway_id`, once `attached_at` is set), signed
with the instance id that attached it (`runs.gateway_instance_id`), and from nobody before
the attach, the run's node included: another instance of the gateway is `409 wrong_gateway`,
under any of its keys, while the run's sending has not ended. A run whose starter gave its
outcome has not ended here: its gateway still sends its last events and its exit. A run
attached before its instance was kept takes the instance of the next attach, batch or
heartbeat its gateway sends while its sending has not ended, written under the run's row
lock and only while it has none, so of two instances one holds it. A gateway's key finds
its run by the gateway and the run's id, whatever workspace the run is in, and never opens
one: a batch for a run it did not attach is `409 wrong_gateway`, and nothing is stored.
The run's workspace, node and instance stay the registration's. What is read for it, the
run configuration its answers carry and the features its events are kept under, is read
under the run's workspace and organisation (`Apiary.Runs.Sender.place_key/2`), and the
delivery is recorded in the run's workspace. Events after the run's end are taken from any
instance of the gateway that attached it, under any of its active keys, as from the
attaching instance: once the run's `dev.qory.run.exited` arrived, it was lost after its
attach, or its events were pruned (`Apiary.Runs.Sender.sending_ended?/1`), a resend from
any of them is deduplicated, only the attaching instance's heartbeat makes a lost run live
again once that instance is known (Liveness, below), a run whose events were pruned is `410` to each, and none of
them gives the run its instance. Another gateway node is still `409 wrong_gateway`, and a
reload stays the attaching instance's.

Once the run's starter has given its outcome (The run endpoint, below), every `2xx` to the
run's batches has a body, `application/json`,
`{"end":{"state":"succeeded","reason":"all_checks_passed"}}`, `reason` left out when the
outcome gave none, until the run's `dev.qory.run.exited` arrives: in the batch, or among
the events the run holds. The answer to the batch that carries the exit, and to every
batch after, has an empty body, as every answer had before. The answer signature's line 4,
the SHA-256 of the body as sent, covers it.

A batch is a non-empty JSON array of at most 1000 objects (the gateway cuts a batch at a
hundred), each with `id` and `subject` (lowercase UUIDs), `type` (beginning `dev.qory.`),
`sequence` (ten digits, from `0000000001`: `0000000000` is no sequence), `source`
(`urn:qory:run:` and the subject), `time` (RFC 3339, in the years 1970 to 9999) and `data`
(an object, nested no deeper than 64 levels), all of one subject. The limits are what the
tables hold: what passes them is stored, and no batch is answered `500`. Only this envelope is
checked: `data` is not validated against the schema of its type, and a type this release does
not know is stored like any other, so a newer Forager's events are kept until a release reads
them. A type outside `dev.qory.` fails the envelope, and the batch is answered
`400 invalid_request`. So is a batch that holds `dev.qory.ping` or
`dev.qory.run.registered`: a run opens with its registration, never with an event, and the
gateway keeps `dev.qory.run.registered` in its record (`Apiary.Runs.Batch`).

What is stored, in one transaction, before the answer:

- the run: the row its registration stored (The run endpoint, below). A batch of a
  subject the key's workspace holds no run of creates one on its first event, in that
  workspace, in state `pending`, with the key that delivered it, the key's node and the
  instance id the request claimed (`Apiary.Nodes.placement/2`), both fixed from then on,
  and the versions the request named; no instance limit holds it, since only a
  registration is admitted. The same subject under another workspace is another run. Two
  first batches at once make one run. The run's row is locked while its batch is stored;
- nothing, for a run retention has pruned. Deduplication is against the events the
  workspace holds, and a pruned run holds none, so a batch delivered again after the prune
  could not be told from a new one and would be folded a second time. The workspace
  therefore wants nothing more of a run whose events it pruned, and says so: `410`, the
  delivery recorded, no event stored. A run that lost
  only its log output (the log's days are shorter than the events') still takes events,
  deduplicated against the ones it keeps, but no `dev.qory.run.log` event: its log events
  are gone, so a replayed one could not be recognised, and one that is new would be older
  than the workspace keeps log output. Such events are answered like duplicates, within a
  `202`. Neither case arises for a run that is alive: retention only prunes a run that has
  ended, and a run marked lost no sooner than 7 days after it was lost
  (`Apiary.Runs.Run.lost_days/0`), so a gateway's record sent after a shorter outage is
  stored;
- each event, as received: `id`, `sequence` as an integer, `type`, `time`, `data`, and when it
  was received. An event already held (the same `id`) is skipped: delivery is at least once.
  An event whose `id` is held by another run of the workspace, or whose `sequence` in its
  run is held under another `id`, is dropped and counted in a log line; it is never an
  error, since sending it again could not help. Events are read back by `sequence`, never
  by arrival;
- the delivery: the key, the instance id, `X-Qory-Delivery`, the subject, how many events it held, how many were
  new, the status answered, and the batch's `X-Qory-Run-Configuration` when it had the shape
  of a digest. A delivery id the key has delivered before is answered `202` again, or `410`
  for a run retention has pruned, and nothing is stored; a run behind a gateway that may no
  longer serve its workspace is refused `410` `workspace_not_served` before this, a
  delivery recorded before included;
- on the run: the count of events, when the last one was received, and the last
  `X-Qory-Run-Configuration` that had the shape `sha256=` and 64 lowercase hex digits.

After the commit, and never failing the request: the key records the time, and the Forager
version and the contract version when the request named them (a request that names none
leaves what is recorded). A repeated delivery
records nothing on the key. The run's events are projected into the run, its connections and its log,
asynchronously; a projection that moves the run's last heartbeat records it as the key's last
heartbeat too, never moving that backwards (Liveness, below). Nothing of a request's headers beyond the above is stored, and neither the signature nor
the body is logged.

## The run endpoint: registration and reload

`POST /v1/runs` registers a run before it starts, and `GET /v1/runs/<run_id>` reloads its
run configuration (`ApiaryWeb.Contract.RegistrationController`,
`Apiary.Runs.Registration`). Both are signed as above. A run that goes through a gateway is
attached by it with `POST /v1/runs/<run_id>/attach` (The attach, below).

**The registration.** `Content-Type: application/json`, the media type compared exactly,
whatever its case and parameters (`415` otherwise), a body of at most 64 KiB, the
contract's `run-registration.schema.json`:

```json
{"version":1,"run_id":"0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d","labels":{"forge":"git.example","repository":"acme/shop"},"about":{"title":"Fix the failing build"},"forager_version":"0.7.0","contract_version":1,"interval_seconds":30,"events":["*"],"time":"2026-10-10T12:00:00Z"}
```

The body is read strictly (`Apiary.Runs.Registration.parse/1`). Each rule it breaks is
`400` `{"error":"invalid_request","names":["<member>"]}`, which names the member and never
repeats a value, `"body"` for a member the contract does not name and a body that is not a
JSON object (the events endpoint's `400` carries no `names`): a member the contract does
not name; a `version` other than `1`; a `run_id` that is not a lower-case
UUID; `labels` that are not an object of at most 16, each key 1 to 64 of `a-z`, `0-9`,
`_`, `.` and `-`, each value a string of at most 256 bytes of UTF-8 with no NUL; an
`about` that breaks any rule of `about` (`Apiary.Runs.About.validate/1`, the rules under
"Assumed"), refused whole here where the fold drops the part that breaks one; a `time`
that is not a date and time in UTC to the whole second, `2026-10-10T12:00:00Z`; a
`forager_version` that is empty or holds a NUL; a `contract_version` that is not an
integer from 1; an `interval_seconds` that is not an integer from 1 to 300; `events` that
are not a list of strings that are not empty. `labels` and `about` may be left out, and
everything else is required. A `time` more than 300 seconds from the server's clock,
either way, is `401`, unsigned, as a GET's stale timestamp is.

The body has one of two shapes, told apart by its members alone. The direct shape is the
one above. The shape through a gateway has `version`, `run_id`, `time`, and optionally
`labels`, `about` and `attach_seconds`, and none of `forager_version`, `contract_version`,
`interval_seconds` and `events`. A body with any of those four is read as the direct
shape, so it must have all four and no `attach_seconds` (`"attach_seconds"` is the member
named then). `attach_seconds` is an integer from 1; left out it is the server's default,
and above the server's ceiling it is the ceiling
(`Apiary.Runs.Registration.attach_window/1`: `config :apiary, Apiary.Runs.Registration`,
`attach_seconds`, 600 unless set, and `max_attach_seconds`, 3600 unless set).

Which shape a key's node may send is decided by its recorded choice of gateway, resolved
as the records are now (`Apiary.Gateways.resolve/1`), never by the body: a node that goes
directly sends the direct shape, and a node whose choice resolves to a gateway the shape
through a gateway.
After the refusals every signed request gets, in the order of the events endpoint's table
(`413`, `415`, a header sent twice, `401`, `429`, the instance id, the contract version,
the body, the `time`), the first of these that applies is the answer:

| Status | When | Body |
|---|---|---|
| `409` | the `run_id` is that of a run of a workspace's queue, on the whole instance, in any state (waiting, claimed, handed over or ended), under any key (A run of the queue, below) | `{"error":"run_id_used"}` |
| `404` | the key may not open a run (`run.post_events`) | `{"error":"not_found"}` |
| `200` | a repeat: a run of this id that registered with the same bytes, by their SHA-256, under any active key of the node that registered it is given the answer it was given, and nothing is stored or admitted again | the run configuration |
| `410` | a run of this id whose events retention has pruned | empty |
| `409` | the key is a gateway's: a gateway registers no run, whatever the shape | `{"error":"gateway_key"}` |
| `409` | the shape through a gateway, from a node whose choice is direct | `{"error":"node_is_direct"}` |
| `409` | the direct shape, from a node whose choice is not direct | `{"error":"node_uses_gateway"}` |
| `409` | the node's choice is its workspace's default, and no default resolves | `{"error":"no_default_gateway"}` |
| `409` | the node names a gateway that may no longer serve its workspace (`Apiary.Gateways.may_serve?/2`) | `{"error":"gateway_not_serving"}` |
| `409` | the gateway the choice resolves to has no active access key | `{"error":"gateway_without_key"}` |
| `409` | a new instance beyond its node's instance limit (`Apiary.Nodes.admit/4`); the refusal is counted on the node | `{"error":"instance_limit"}` |
| `409` | any other run of this id: registered with other bytes, or by another node even with the same bytes, or created by events that came without a registration | `{"error":"run_id_used"}` |
| `503` | a managed workspace whose run configuration cannot be read, a run key that cannot be made for the gateway, or a run that cannot be stored: never a run without its policy | `{"error":"unavailable"}` |
| `200` | the run is stored | the run configuration, or for a run through a gateway its run key |

**A run of the queue.** A node pool's starter claims the runs a workspace queues (the
provisioner contract, `contracts/provisioner/v1` of `qoryai/integrations`). Qory Apiary
serves revision 1 of that contract alone: a request whose `X-Qory-Contract-Version` names
any other revision is refused `400` `unsupported_contract_version`, and each claim answer
has `revision` 1. A claim answer is a request for a machine: `version`, `revision`,
`dispatch_id`, `pool_id` (the claiming key's node pool), `lease_until`, `run_code`,
`gateway_url` and `max_lifetime_minutes`, 90 for a prebuild and 1470 for any other claim,
sent with `Cache-Control: no-store`, and nothing of the run, neither its `run_id`, its
`step`, its `access`, its `target` nor its `work_item`. The answer has no `machine`, so
the starter uses its default machine type. An explore run's `run_settings` has
`time_limit_minutes`, an integer from 15 to 1440, after its other members, when a time
limit resolves for the run's workflow (`Apiary.Stacks.workflow/2`): the limit set for
that workflow at the run's target, else the one set at its workspace
(`Apiary.TimeLimits`). With no limit at either place, or no workflow for the run, the
member is absent, and the run takes the default of the workflow's stack, which the
machine applies. The claim registers the run, and the run endpoint refuses,
under any key, a registration whose `run_id` is that of such a run, waiting, claimed,
handed over or ended, with the signed `409` `run_id_used`, decided
first: before the stored answer to a repeat and before the instance limit, the Forager
contract giving the other causes and their order. Qory Apiary reads "first" as the first of
the run endpoint's checks, so the lookup (`dispatch_runs.run_id`, unique on the instance,
read across every workspace and organisation) comes after the refusals every signed request
gets, the body's `400` and the `time`'s `401` included, so nothing is looked up for a
request that does not verify or is not fresh, and before every answer that depends on the
key: the `404` of a key that may not open a run, the repeat, the `410`, the resolution's
`409`s and the instance limit. A node's key, a node pool's and a gateway's, one of a
workspace or of an organisation, are given that one answer for such an id, and the answer
never tells which kind of key asked or what the key may do. The refusal stores nothing
beyond what every verified request leaves, the spent token of the key's rate and the
instance's sighting (`Apiary.Nodes.seen/3`): no run, no count of the node's instance limit,
no use recorded on the key. A lookup the database cannot answer is `503` `unavailable`. A
run of the queue is given its `run_id`, a fresh UUID, when it is queued, before anyone
outside the instance learns it, and the id never changes, so no registration can come
between the queue and the lookup.

The events endpoint holds such a run the same way. A batch whose subject is its `run_id`,
from a key that does not reach a run under that id, is `409` `run_id_used`, before or
after the claim, decided inside the batch's transaction after the `404` of a key that
may not post and before anything of the batch is stored. A key reaches the run when it is
a key of the run's workspace, or a gateway's that may serve the run's workspace
(`Apiary.Gateways.may_serve?/2`), at the workspace's level or the organisation's. Before
the claim (the run waiting, or ended before a claim) there is no run, so no key reaches
one, and every key is refused. After it the run is registered, and a key that
reaches it keeps the answer it had: the gateway that attached it is taken, another key of
its workspace, the pool's included, and another gateway that may serve its workspace are
`409` `wrong_gateway`, and a run whose events were pruned is `410`. A key of another
workspace, and a gateway that may not serve the run's workspace, are refused
`run_id_used`, and open no run under that id.

The claim registers the run, in the claim's transaction, with the run of the queue and
its dispatch held, through the gateway the pool's choice resolves to: the run's `run_id`
is the one the run of the queue was given, and so is its instance id; its labels and its
run variables come from the target, the work item's or the prebuild's collection's, and
what it is about from the step and the work item, never from the request; a prebuild's
input is the `environment_ref` its run of the queue was queued for. The claim encodes
the run's documents once (the run contract's `documents.schema.json`: `step`, `domain`,
`access` and `target` together or neither, `work_item`, `run_settings`, `stack`,
`workflow` and `harness_hidden` together or none, and `inputs`) and keeps the bytes on
the registered run (`runs.run_documents`); every redemption of the run code answers them as they are. The
201 of that redemption takes at most 1 MiB, what the gateway's relay passes back: the
claim measures the rest of the 201 with a run key of the run's grant and the server's
keys, keeps 1,024 bytes free for a second server key, and gives the documents the rest;
an explore run's input leaves out its oldest comments to fit, and a claim whose documents
cannot fit is `503` `unavailable`. A prebuild's documents have its destinations in the
instance's registry: `image_destination`, `<QORY_REGISTRY>/<instance>/<organisation>/targets/<target>`,
and `environment_destination`, `<QORY_REGISTRY>/<instance>/<organisation>/environments/<key>`,
or, where an environment record of the organisation has an image under that name,
`environment_image`, that image by its digest (`Apiary.Registry.RunAccess`). They are the
names the run's registry tokens grant. Prebuilds run only on an instance with a registry
(`Apiary.Registry.configured?/0`): the `registry` feature on, and `QORY_REGISTRY` set to
an address whose host has a dot or a port, or is `localhost`. On any other instance no
prebuild is queued or claimed, no run waits for one, and an explore run starts in its
pool's default image; a prebuild queued before stays waiting. The instance's registry
name, the `<instance>` part, is made at the first claim of a prebuild where it is not
made yet; a claim where it cannot be made is `503` `unavailable`. A prebuild of a
workspace that serves no run configuration is given, at its attach, the workspace's
default policy, in `observe` with no rules, composed with the registry's members; where
that document cannot be composed, its attach is `503` `unavailable`. The registered run
has no run key. The claim answers `run_code`: a run code, `qecr_` and 26 characters, then
`.` and the fingerprint of the instance's key, which the machine redeems once at
enrolment for the run key, within 15 minutes of the claim (Enrolment). The registered
run keeps the gateway the pool's choice resolved to (`runs.gateway_id`): the code is bound
to that gateway, and is redeemed only through its relay. The run key names
the gateway and the pool. It is made at the first redemption, issued then, with its
attach window of 600 seconds from then; until the redemption the run's attach window is
the code's 15 minutes, so a run whose code is never redeemed is lost at the code's
expiry. A claim is `409` `no_gateway` when the pool's choice of gateway resolves to none,
and claims nothing. A claim Qory Apiary cannot make, a run key that cannot be made for
the gateway's address among the causes, is `503` `unavailable`, after which nothing was
written. When what the run is made from can no longer be formed, Qory Apiary ends the
run of the queue and its dispatch in the claim's transaction and claims the next run
that waits: a prebuild's collection ended, moved to another workspace, unassigned or
left without a target (`collection_ended`), a prebuild of an `environment_ref` its
collection no longer has (`superseded`), run variables that break their rules for the
target (`variables_invalid`), a work item whose ticket is no longer kept
(`ticket_gone`), or an input that breaks the explore contract's rules for it, or a work
item with no target in a domain that requires one (`inputs_invalid`).

**The run's harness.** An explore run's documents have `workflow` and `harness_hidden`
together, or neither; a prebuild's have neither, and none of `target_version` and
`harness`. `workflow` is the workflow of the one stored stack with a workflow at the
run's places: its workspace, and its target when it has one
(`Apiary.Stacks.workflow/2`). With no such stack, or two or more, the run has no
workflow, so its documents have none of the four members. A run with a workflow waits
until a job has walked its harness (`Apiary.Harnesses.Walk`); a claim takes no run whose
walk has not resolved, and a walk that fails ends the run before it starts, with the end
cause `harness_unresolved` and the failure's code. The walk takes the first of four.
First, the target's harness file, under every harness choice. Second, a stack chosen for
the run's target (`Apiary.Stacks.chosen_for/4`): its stored document applies and is the
documents' `harness`. Third, the workspace's harness choice, else the harness its
organisation shares with every workspace: its document applies the same way. Last, the
Qory harness: the harness of the workspace type's definition
(`Apiary.Lingo.Domain.Definition`) at the newest version the release ships. A stored
document's base is read at the `ref` of its row's version (`Apiary.Stacks.version_ref/3`):
the Qory harness at "latest" at the commit of the newest version the release ships, a
harness repository at the branch, tag or commit saved; the documents' `harness` has that
`ref`. The walk reads the target's harness file at the target's head, in a workspace
whose domain has harness files and for a target that a live collection of the workspace
has; the version that read returned is the run's `target_version`, whichever harness
then applies. A file whose harness section has `extends`, or lists modules without it,
applies, and the documents have no `harness`: the machine composes the file at
`target_version`. A file with neither is passed over. A stored document or the Qory
harness is the documents' `harness`, as `{"harness": <section>}`. The owner of a stored
document is the organisation of the person who saved it, when that person saved it as a
member acting in that organisation; for an instance admin who saved it with no such
membership, it is the instance's organisation; it is unknown once the owner organisation
is deleted. `harness_hidden` is `true` when the run's organisation is a client of an
operator (`Apiary.Edition.operated?/1`, which the core edition, `Apiary.Edition.Core`,
answers `false`), or when a stored document applies and its owner is not the run's
organisation. A document the instance's organisation owns is hidden from the runs of
every other organisation, whether the instance has one organisation or several, and an
unknown owner is never the run's organisation. Workspace settings › Workflow and the
set-up's Harness step write a stored stack at the workspace's level, and so do tests and
the demo (`mix apiary.demo.console`, which stores one for the workspace Main); no
endpoint sets one.

The starter says it started the machine for the dispatch (`dispatched.schema.json`)
before the dispatch's `lease_until`, and that hands the dispatch over; so does the first
redemption of the run code before `lease_until`. A dispatch handed over keeps no lease:
it never goes stale, and its slot stays held until its run ends. The refusals of
`dispatched` come in the contract's order: `403` `forbidden` for an unknown dispatch,
another pool's, or a key the action is refused to, one answer; `410` `gone` for a
dispatch that ended; `409` `lease_expired` for a dispatch not handed over that is stale
or past its `lease_until`; and `503` `unavailable` last, after which nothing was written.
A lease that lapsed unswept is freed first, and that is committed: the run waits in its
queue again, or a prebuild ends `superseded` while another prebuild of its collection,
pool and `environment_ref` waits, and is answered `410` `gone`. A dispatch handed over accepts `dispatched`
whatever its `lease_until`, and records the time of the first one alone. When a run
leaves the claim other than by its handover, its lease lapsing or a release ends its
registered run `failed`, with the reason `lease_lapsed` or `machine_not_made`, and the
close of its work item deletes it with the run code; either way the code redeems
nothing from then on. The failed run keeps its id and its page, and leaves the run of the
queue, so the next claim registers a new run.

Once handed over, such a run ends with its registered run, in one of three ways, the first
to come deciding (`Apiary.Dispatches.RunEnd`): its `dev.qory.run.exited` once folded,
whatever its state, ends it `run_ended`; a `dev.qory.run.refused` once folded ends it
`run_refused`, for a run that is not a prebuild; and the lost-run check ends it `lost`
when its gateway never attached it by its `attach_by`, when it has no exit by its
backstop, 87,300 seconds (24 hours and 15 minutes) after its attach for the step
`explore` and 4500 (1 hour and 15 minutes) for `prebuild` (Liveness), or when it went
600 seconds without a heartbeat after its attach and before an exit: with the gateway
down, no exit reaches Qory Apiary, and that end frees the slot. A heartbeat stored and
not yet folded counts by its arrival. Such a silent run is `lost` for good: its registered
run is set `lost` and its backstop moved back to the end of its silence, and no heartbeat
or start folded after that end brings it back, whenever it arrived; its exit still changes
the record. A
prebuild the lost-run check ends `lost` records that end as its last build's failure on
the environment record of its collection and of the pool that claimed it, `lost` at its
`attach_by` or after its silence and `timed_out` at its backstop, with no reason. A
prebuild its exit ends, `run_ended`, records it there too when the exit's state is
`failed` or `lost`, as that state, with no reason; any other exit records no failure. The
record keeps its last good build. While the prebuild's `environment_ref` is still its
collection's, the first loss of that ref (`lost`) queues one more prebuild of it for
the pool; a `failed` exit, a `timed_out` end or a second loss ends the runs held for
that build `build_failed`, with the outcome `error`, unless another live pool keeps an
image of the target from its collection's `environment_ref`; a prebuild of another pool,
in any state, keeps no run held, and a run that comes to wait later is held again (see
the hold below). The
check and the projection's end hold the target's collections `FOR SHARE`, the work
items whose runs wait for the build `FOR KEY SHARE`, then that record `FOR UPDATE`,
before the run of the queue, as a release holds the record; a prebuild whose
`environment_ref` is older than the record's image's records no failure, and ends all the
same; so does a prebuild whose reported image is the record's. Its dispatch ends with it,
with the same end cause, a stale dispatch of it with `run_ended`, and the slot the
dispatch took at its claim is freed once (`dispatches.slot_freed_at`, set only where it is
empty). An end after the first changes none of them. A run of the queue takes no outcome:
the outcome endpoint answers a pool's key for a run the pool claimed `404`, as it answers
a key for a run the key is not bound
to, and stores nothing (`Apiary.Runs.Outcome`). A node's keys keep the outcome endpoint
for the runs the node registers itself. Each end locks the run of the queue, then the
registered run, then writes the dispatches; an end by an exit or by the lost-run check
first locks the run's work item `FOR KEY SHARE`, or a prebuild's target's collections,
waiting work items and environment record as that paragraph says; the end of a run whose
exit reason is `image_missing` holds the collections of its image, its work item
`FOR UPDATE` and the environment records of its image first. So two ends of one run take
turns, and an exit that comes as the check
loses the run is either taken first, its end cause `run_ended`, or after it, the end cause
staying `lost`.

A prebuild reports the image it built in its record, `dev.qory.run.built`, with `image`,
pinned by its digest, `size`, `commit` and `environment_ref` (`Apiary.Dispatches.Built`).
The projection that folds it stores the image on the environment record of the
prebuild's collection and of the pool that claimed it, after its pass has committed and
before the run's end, in a transaction that holds that record: the image, its size, its
commit, the `environment_ref` reported, as it is, the `environment_ref` the prebuild was
queued for (`built_ref`), when it was recorded, the target the run was registered for,
and when the prebuild took the `environment_ref` it built. The last failure and the
lost ref are cleared, nothing is queued, and the workspace's waiting claims are told, so
a run held for that build is taken. Only the event of a run registered for a
run of the queue for the step `prebuild` that was handed over is stored, whether its run
of the queue has ended or not, so an event that arrives after the exit, or after the
lost-run check ended the prebuild, is stored as one that arrives before it. The event of
any other run is kept with the run's other events, and records nothing; so does an event
whose `image` is not a lower-case name of at most 255 characters with `@sha256:` and 64
lower-case hexadecimal digits, whose `size` is not an integer from 1 to 2^53 - 1, whose
`commit` is not 40 or 64 lower-case hexadecimal characters, or whose `environment_ref`
is not 1 to 200 characters or contains U+0000, or whose `environment_image` breaks the
rule of `image`. So does an event whose `image` is not at the run's `image_destination`:
its name before `@sha256:` must be exactly the `image_destination` of the documents the
registered run keeps; and one whose `environment_image` is not at exactly its
`environment_destination`, or is not exactly its `environment_image`. Such an event is
logged as a warning with the run's public id. Of two such events of one run, the lower
sequence counts, and only the projection that folds it stores it: a later projection of
the run, and a rebuild of its projection, store nothing. A build whose prebuild took its
`environment_ref` before the prebuild that made the record's image took its, and the
build already on the record, change nothing.

A run of a work item that started in the image its pool's environment record gave it,
whose `dev.qory.run.exited` is `failed` with the reason `image_missing`, ends
`run_ended` as any exit ends it, and in the same transaction the image is cleared from
the records of that pool built for the run's target with that image, so no run is
given it again. For each such record whose collection is live, assigned to the pool's
workspace, with a target and an `environment_ref`, a prebuild of the collection's
`environment_ref` is queued for the pool, as a Rebuild queues it, unless one of that ref
waits unclaimed. The next run of the work item's take in is then queued with the attempt
total raised by one, so the work item loses no attempt: attempt 2 of 3 ends, attempt 3
of 4 waits, held for that build (`dispatch_runs.image_requeue`). The run's explore
input counts only the runs of the take in that started, so that run's `run` is
`{"attempt": 2, "of": 3}`, within the explore contract's 1 to 3 of 3. A second
`image_missing` on a run queued so ends it with no requeue. No run is queued while the
work item is not in Explore, is in another workspace or at another take in. That end
first holds the connections and then the collections of those records `FOR SHARE`, by
id, as a Rebuild holds them, then the run's work item `FOR UPDATE`, then those records
`FOR UPDATE`, before the run of the queue. An end by the lost-run check that read the
run before its exit was folded, and so holds none of them, ends nothing; the
projection's end, or the next check, ends it.

A run its gateway refused before it started (`dev.qory.run.refused`, with a code such as
`model_key_missing`) ends `run_refused` at its first refusal and is not queued again. The
projection that folded the refusal ends the run of the queue after its pass has committed,
in a transaction that locks the run of the queue, then the registered run, and nothing
before them: it writes the run of the queue once. The run of the queue keeps the refusal's
code as `end_detail` (nil when the event's code is not a code), and its dispatch ends with the same end cause; the slot is
freed once. The registered run stays failed with the code as its reason and `refused_at`. The starter's
release of the dispatch after this end is `410` `gone` and queues nothing, and the claim
never offers the run again. A refusal that comes after any other end, or while an exit
decides over it, changes nothing: the run keeps the end cause that came first. A
refusal folded whose end the projection did not write is ended by the lost-run check at its
next tick. A prebuild's refusal ends nothing of the queue. A work item's Explore reads a
run ended `run_refused` as a run with no result and the outcome `error`, as it reads the
end causes of a claim that cannot form a run (`Apiary.WorkItems.Explore`).

The release gives a run back (`release.schema.json`), with the starter's `reason`, in one
transaction (`Apiary.Dispatches.Release`). A release is accepted only before the
handover: before `dispatched` and while the run code is unredeemed. The refusals come in
the contract's order: `403` `forbidden` for an unknown dispatch, another pool's, or a key
the action is refused to, one answer, decided before any lock and writing nothing; then a
lease that lapsed unswept is freed, and that is committed whatever follows; `410` `gone`
for a dispatch that ended, or of a run that ended; `409` `machine_exists` for a dispatch
handed over, by its `dispatched` or by the redemption of its run code; `409`
`lease_expired` for a dispatch that is stale or past its `lease_until`; and `503`
`unavailable` last, after which nothing was written. Else the signed `204`, with no body:
the dispatch ends `released`, its slot is freed, its registered run ends `failed` with
the reason `machine_not_made`, and the run waits again, as when its lease lapses: an explore run with the
same `run_id` and `queued_at`, its work item left exploring; a prebuild with its
`environment_ref`, or it ends `superseded` while another prebuild of its collection,
pool and `environment_ref` waits. A release records no failure on a prebuild's environment
record. Qory Apiary keeps every release's reason in its audit entry and on the
dispatch, and the page of the failed run shows it. A release holds its run's work item, or a prebuild's environment record, before
anything of the queue, then locks as `dispatched` does; a work item is never locked after
a run of the queue, so a release, a close, `dispatched`, a redemption and the sweep take
turns, and of two releases at once one acts and the other is `410` `gone`.

The machine log is what the machine a starter created for a dispatch wrote, uploaded once
per dispatch, before or after the dispatch ends, whether or not a run opened
(`machine-log.schema.json`, `Apiary.Dispatches.MachineLogs`). The body is `version` 1,
`time`, `log`, text of at most 786,432 characters with no U+0000, and an optional
`truncated`; anything else is `400` `invalid_request`, and a body over 1 MiB is `413`. The
refusals come in the contract's order: `403` `forbidden` for an unknown dispatch, another
pool's, or a key the action is refused to, one answer; `409` `machine_log_exists` for a
dispatch with a machine log already; and `503` `unavailable` last, for a file that could
not be written, after which nothing was kept. It is never `410` `gone` or `409`
`lease_expired`. Else the signed `204`, with no body. The text is kept as sent, as a file
named by the dispatch id alone, mode 0600, in the folder `APIARY_MACHINE_LOGS_DIR` names
(`Apiary.Dispatches.MachineLogStore`), and a row of `dispatch_machine_logs` keeps its size
in bytes, `truncated` and when it was uploaded, linked to the dispatch and through it to
the run. With no folder set, every upload is `503` `unavailable` and one log line says the
variable is not set: nothing is kept and nothing is dropped unseen, so the starter's next
upload succeeds once the folder is set. The starter replaces each line that contains
`qak_`, `qrk_` or `qecr_` before the upload; Qory Apiary keeps the text as sent. Only an instance admin reads a
machine log (`Apiary.Dispatches.machine_log/2`). The retention job deletes a machine log
`MACHINE_LOG_RETENTION_DAYS` days after its upload, 30 unless set, from 1 to 365, or the
value an instance admin saved, file then row, and an hour-old file whose row is gone; the
purge of an organisation or a workspace deletes the files of its machine logs before its
rows. No audit entry is written for an upload. Once the log is kept, a dispatch handed over
whose run has not redeemed its run code ends that run at once: the run is `failed`, with
the reason `machine_stopped`, and its run of the queue and the dispatch end `lost`, as the
lost-run check ends them at the code's expiry (`Apiary.Dispatches.RunEnd.machine_stopped/1`).

No run is stored on any refusal. The run configuration is read before the transaction,
outside the node's lock; the instance limit is checked inside it, first, under the node's
row lock, so a request both refuse is refused by the limit. A node runs one instance at a
time, a pool up to its limit, and an instance counts while one of its runs is alive. Two
registrations of one run
at once store it once: the other is a repeat when its bytes and key are the first's, and
`run_id_used` otherwise. A repeat whose run configuration is no longer stored, because its
target was deleted, is given the configuration in force now for its labels. An
exception while the registration is read or stored is logged as "a registration could not
be stored: <Module>", the exception's module and nothing of the request; a `503` because
the run configuration could not be read logs nothing.

What is stored, in one transaction, before the answer: the run, in the key's workspace, in
state `pending`, under the key, on its node and the instance the request claimed
(`Apiary.Nodes.placement/2`), with `registered_at`, when this server took it, the
registration's labels, `about` and `interval_seconds` (`registration_labels`,
`registration_about`, `registration_interval_seconds`), the SHA-256 of its bytes (`registration_digest`), by which a repeat
is told from another registration, and the digest of the run configuration it was given
(`registration_answer_digest`). Its `forager_version` is the one `User-Agent` names, else
the body's, and its `contract_version` the header's. The projector never writes these
fields, so a rebuild keeps them. The run's projection starts at sequence 1: the registration stands
for the record's sequence 1, `dev.qory.run.registered`, which is never posted
(`Apiary.Runs.Run.projected_from/1`), so its events count from sequence 2; a run its
batches created starts at 0. Until an event is projected, whichever start the run has,
the run page's Details say it is projected through `#0000`. After the
commit, and never failing the
request, the key records the time and the versions, and the run is broadcast as changed.
The run's batches are stored on the same row, and its `run.started` moves it to
`running`.

**The answer** to a registration and to a reload is a signed `200`,
`Content-Type: application/json`, whose body is the run's run configuration, with
`X-Qory-Run-Configuration: sha256=<lowercase hex>` and `ETag: "sha256=<hex>"` (the same
string, quoted), always, `X-Qory-Configuration`, and `Cache-Control: no-store,
no-transform`:

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
key's workspace for the target the registration's labels name, by the workspace's
domain (`Apiary.Lingo.Domain`), whose software domain reads `forge` and `repository`. A
target the workspace has not seen, one with neither rules nor a mode override, and
labels that name none (or one label of the two) get the workspace's baseline.
`egress.mode` is the workspace's, unless the target overrides it, with `observe` or
`enforce`; a target that does not follows the workspace, later changes of the
workspace's mode included, and a target the workspace has not seen gets the
workspace's. The rules resolve the same under either mode: a locked rule of the workspace
holds in a target's document whatever its mode, and a deny holds in either mode, since
`egress.deny` is decided first: under `observe` the gateway denies what `deny` names and
nothing else, and `allow` says what `enforce` would reach. `about` never selects a policy:
the policy is chosen by the registration's labels alone.

A workspace whose policy nobody has made, or any workspace on an instance without the
`security` feature, and a key `Apiary.Access` refuses `run_configuration.fetch` serve no
run configuration: a registration is answered `{"version":1}`, the document of no policy
(`Apiary.Policy.Render.no_policy_document/0`), with its digest, and nothing is rendered.

**The image.** A run of a workspace's queue that is not a prebuild (A run of the queue,
above) is given the image the node pool that claimed it recorded for the run's target
(`Apiary.Environments.image_for/2`): of the pool's builds for that target, the newest
whose `environment_ref` (`built_ref`) is its collection's `environment_ref`; with none,
no image, and the run starts in the pool's default. The claim chooses it and keeps it on
the registered run (`runs.configured_image`), and the attach gives the run that image; a
run claimed before that rule has it chosen at the attach.

**A run held for its build.** In a workspace whose domain has prebuilds, a waiting run of
a work item whose target a live collection names with an `environment_ref` waits for
the pool's build of that `environment_ref`: a pool's claim does not take it while the
pool has no such image (`Apiary.Environments.held/2`), and gives it that image once the
build is recorded. A pool's claim queues a prebuild of the collection's
`environment_ref` whenever it holds such a run and no prebuild of that ref for the pool
waits, is claimed or is handed over, so a key change while runs wait is built by the
next claim; nothing else queues a build ahead of a run, apart from a member's Rebuild and
an image found missing. The claim holds the collections it queues a build of
`FOR SHARE`, by id, before the pool's row. A run whose target no collection names, or of
a workspace whose domain has no prebuilds, waits for nothing and starts in the pool's
default. With the feature `security`, a run whose target's run configuration in force
names an image in its `security_policy` waits for nothing, queues no build and is not
ended by a build's failure: it starts in the policy's image.

A run given an image has its configuration composed for it
(`Apiary.Policy.ComposedConfiguration`), `image` beside `security_policy` and never
inside it, the workspace's document otherwise unchanged:

```json
{"version":1,"image":"registry.example.com/acme/shop-env@sha256:<64 hex>","security_policy":{"version":1,"egress":{"mode":"enforce","allow":["api.example"]}}}
```

and `{"version":1,"image":"…"}` where the workspace serves no run configuration. Its bytes
are canonical, as a stored document's are, and its digest is theirs. A composed document is
kept by its digest and the configuration it was composed from, one row per document and
configuration of a workspace (`composed_run_configurations`), since leaving a policy's
`image` out can make two configurations give the same bytes; a row goes with its
configuration and with the workspace. Where the workspace's policy names an image (`security_policy.image`) at a
run's attach, no run is given one beside it: the run starts in the policy's, and the two
never both name one. The attach keeps what the run started in (`runs.started_image_from`
and `runs.started_image`): the image given at the top level, the image its policy named, or
none. Forager fixes the image when the run starts: it takes a reload only when the reload
names, at the top level, the image the start named there, or none as the start did, and
selects the image the run started in. So when the policy in force names another image than
the run started in, or none where the run started in one, or one where it started in none,
the reload carries the start's image that way. A run given an image at the top level keeps
it there, beside the policy in force without its `image`. A run that started in the image
its policy named is given the policy in force with that image as its `image`, and nothing
at the top level. A run that started in no image is given the policy in force without its
`image`. The rest of the policy applies at once, the policy's image from the next attach,
and the two still never both name one. A policy that selects what the run started in is
reloaded byte for byte as stored. A run that attached before the start was kept is reloaded
as it was. A
prebuild whose workspace's policy names an image is given that policy without its `image`,
the rest as stored, so a prebuild always builds on the pool's default. Every other run, a
run a node registered itself, a run with no recorded image and a prebuild under a policy
that names none among them, is given the stored bytes, under their digest, as above, until
its policy comes to select another image than it started in. A
run is behind when the digest it reported is not the one it would be answered now, the
configuration in force composed for it as its reload would be. A page that names the
version a digest stands for reads a composed digest as the configuration it was composed
from, the one in force when the same bytes came from several; a digest a configuration was
stored under always names that configuration. The events endpoint takes a reported digest
as in force only when it is what the run would be answered now.

**Through a gateway.** A registration whose node's choice resolves to a gateway is
answered with no run configuration: a signed `200`, `application/json`,
`{"version":1,"run_id":"<run_id>","run_key":"qrk_…"}`, with `X-Qory-Configuration` and
neither `X-Qory-Run-Configuration` nor `ETag`. The run key (`Apiary.Runs.RunKey`) is
`qrk_`, the payload in base64url without padding, `.`, and the 64-byte Ed25519 signature
in base64url without padding, under the instance's signing key (`Apiary.SigningKey`),
over `qory-run-key-ed25519-v1`, a line feed and the payload's bytes
(`Apiary.Contract.SignedMessage.run_key/1`); at most 2048 characters. The payload's
members, in order: `version` 1, `signer` (the signing key's fingerprint), `run_id`,
`workspace` (`ws_`), `node_id` (the registering node or pool, `nd_` or `np_`), `gateway`
(`ng_`), `gateway_url` (the gateway's `https` origin), `gateway_public_key` (the gateway's
active keys, at most two, oldest first, each `{"alg":"ed25519","public_key":…}`),
`instance_id` (the registration's), `issued` and `attach_by` (UTC, whole seconds;
`attach_by` is `issued` and the window granted). A gateway's address is the contracts'
`gateway_url` (`Apiary.Contract.GatewayUrl`): `https://`, a host of DNS labels or an IPv6
address in brackets, and an optional port from 1 to 65535, with no user information,
percent-encoding, underscore, trailing dot, path or query, at most 300 characters. A
gateway's form checks it (`Apiary.Nodes.Node.validate_url/1`), the database holds every
gateway to it (`nodes_url_check`, validated: the migrations stop while a gateway's
address is outside it), and a run key is made only for such an address. A run key that
cannot be made is `503`, logged as "no run key could be made for a run through a
gateway: invalid".

The run is stored as a direct one is, on the registering key's node and instance, but
with no interval, no answer digest and no Forager version unless `User-Agent` names one,
and with the gateway (`gateway_id`), the payload's exact bytes (`run_key_payload`) and
its signature (`run_key_signature`), when it was made (`run_key_issued_at`) and the end of
its window (`attach_by`). A repeat is given the same run key, byte for byte, from the
stored payload and signature, whatever key the instance signs under by then. A run id is unique per workspace, and per gateway among the runs that go
through it.

**The attach.** `POST /v1/runs/<run_id>/attach`, signed by the gateway's key,
`application/json`, its body read raw up to 64 KiB, is how the gateway a run key names
takes the run on (`Apiary.Runs.Attach`, `ApiaryWeb.Contract.AttachController`):
`{"version":1,"run_key","interval_seconds","events","forager_version","contract_version","time"}`,
every member required, read as a registration's same members are; a member the contract
does not name is `400 invalid_request` with `"body"`, and a `time` more than 300 seconds
from the server's clock `401`, unsigned. Then, the first that applies:

| Status | When | Body |
|---|---|---|
| `409` | the key's node is not a gateway | `{"error":"not_a_gateway"}` |
| `400` | the run key does not verify under the instance's signing key, its `run_id` is not the path's, or it is not, byte for byte, the run key the run was given | `{"error":"run_key_invalid"}` |
| `401` | the run's workspace or organisation is out of use (`Apiary.AccessKeys.place_in_use?/2`); unsigned | `{"error":"unauthorized"}` |
| `404` | `Apiary.Access` does not let the run's workspace post (`run.post_events`) | `{"error":"not_found"}` |
| `409` | a repeat, as below, while the gateway may no longer serve the run's workspace (`Apiary.Gateways.may_serve?/2`) | `{"error":"workspace_not_served"}` |
| `200` | a repeat: the gateway node and the instance id that attached the run, under any of the node's active keys, while the run is live, whatever the body | the answer it was given, by its stored digest |
| `410` | the run has ended: an exit, an outcome, a release after its handover for a run of a workspace's queue before such a release was refused (A run of the queue, under The run endpoint), lost after its attach, or its events pruned; or its record is gone; or it is a prebuild whose run of the queue ended `prebuilt`, as a report of the image it built ended one before that report left the provisioner contract | empty |
| `409` | never attached, and past `attach_by` on the clock read once the run's row is locked, or already `lost` (the lost-run check at `attach_by`, or its instance cleared) | `{"error":"run_key_expired"}` |
| `409` | the run key names another gateway | `{"error":"wrong_gateway"}` |
| `409` | the gateway may no longer serve the run's workspace (`Apiary.Gateways.may_serve?/2`) | `{"error":"workspace_not_served"}` |
| `409` | another gateway node attached the run, or another instance of this one, while the run is live | `{"error":"run_attached"}` |
| `503` | the run configuration cannot be read, or the attach cannot be stored | `{"error":"unavailable"}` |
| `200` | attached | the run configuration, with `labels` and `about` |

The checks after the run key run under the run's projection lock and its row lock, so two
attaches of one run take turns. The run key names the gateway the run was registered for,
so another gateway node is refused `wrong_gateway` before `run_attached`; `run_attached`
is reached by another instance of the gateway that attached the run, the instance id its
`X-Qory-Instance-Id` names. A gateway that restarts keeps its instance id, so it takes its
run on again. A run attached before the instance was kept has none, and the first instance
of its gateway that attaches it again is given the answer and holds it from then on. The
answer is the run configuration in force for the run's labels, read under the run's
workspace and organisation, its bytes with `,"labels":…` and `,"about":…` added before the
closing brace, each only when the registration had some, with `X-Qory-Run-Configuration`
and `ETag` of the configuration's digest, not the body's, so that a reload and the run's
batches carry the same digest, and `X-Qory-Configuration`. For a run given an image, and a
prebuild under a policy that names one, the configuration is the composed document and the
digest is the composed document's (The image, above); a repeat is given it by the stored digest. The run keeps
`attached_at`, `attach_interval_seconds`, the digest given (`attach_answer_digest`), the
instance id the attach was signed with (`gateway_instance_id`), the attach's Forager
version (the `User-Agent`'s first) and contract version, the image it was given at the top
level (`configured_image`), nil for none, and what it started in (`started_image_from`:
`top_level`, `policy` or `none`; `started_image`, nil for none).

**The reload.** `GET /v1/runs/<run_id>`, signed with `X-Qory-Timestamp`, is answered only
to the active keys of the node that registered the run, or, for a run through a gateway,
of the gateway that attached it and from the instance that attached it
(`Apiary.Runs.Sender`), under the run's workspace: a run through a gateway not
attached yet is `404` to everyone, and so is a reload from another instance of its
gateway; a run id the
key's workspace does not hold, a run another node registered, a run its batches created
without a registration, even for the key they came with, and a `run_id` that is not a lower-case UUID are `404`
`{"error":"not_found"}`. Its `200` is the run configuration in force now for the labels the
run registered with, and no others, with the headers above. A run whose events retention
has pruned is reloaded all the same: `200`, never `410`. A run through a gateway that may no
longer serve the run's workspace (`Apiary.Runs.Sender.serves?/2`) is `410`
`{"error":"workspace_not_served"}`, never its policy, before any `404` below. A run whose
attach composed its configuration is given the configuration in force now composed the
same way, with the image it was given at its attach, under the composed digest: Forager
fixes the image when the run starts, so every reload names the same one, and a policy
change is the only reason the digest moves. A policy in force that selects another image
than the run started in is composed with the start's image (The image, above), under a
digest that maps back to the policy's, so the run is not shown behind it. A reload on a workspace with no policy, or a
policy removed mid-run, answers `404`, a run given an image included; only a run whose
attach was answered `{"version":1,"image":"…"}`, its image where the workspace served no
run configuration, is answered that again there, and only while the workspace has never
stored a run configuration: once the workspace has a policy, a run may have taken it on a
reload, so a reload that finds it no longer served answers `404` for that run too. A policy
removed mid-run never loosens a run that has already started, and the next run gets the new state when it registers. When the
configuration cannot be read the answer is `503 {"error":"unavailable"}`. To the gateway,
any answer but `200` is a reload that failed: the policy in force stays, and it is tried
again on the next answer.

**The outcome.** `POST /v1/runs/<run_id>/outcome`, signed, `application/json`, its body
read raw up to 4 KiB (`ApiaryWeb.Contract.RawBody`), is how a run's starter says how the
run went (`Apiary.Runs.Outcome`, `ApiaryWeb.Contract.OutcomeController`):
`{"version":1, "state"?, "reason"?, "time"}`. `state` is `succeeded`, `failed` or
`cancelled`, and none is `cancelled` with the reason `stopped`. `reason` follows the rule of
an exit's reason (How a run ends), and one that breaks it, is one of Forager's reserved
codes, or is `released`, a reason Qory sets itself (A run of the queue), is dropped, the
outcome kept. `time` is held to 300 seconds of the server's clock,
outside of which the answer is `401`, unsigned. A member the contract does not name is
`400 invalid_request` with `"body"`. After the refusals every signed request gets, and the
body's: a key `Apiary.Access` does not let post is `404`, and so is a run of a
workspace's queue, which a node pool claimed, whatever the key (A run of the queue);
the same outcome again under any
active key of the run's node is `200` again, nothing stored or changed: the same state and
reason as stored, after the rules above, whatever the bytes, so a new `time`, a reason the
rules drop and no state at all (cancelled, `stopped`) are the same outcome, and the first
outcome's `time`, arrival and digest stay; a run id the workspace does not hold, a run of
another node and a run whose events retention has pruned are `404 {"error":"not_found"}`;
a run that was given another outcome, another state or reason, is
`409 {"error":"outcome_given"}`; else the outcome is stored on the run, under the run's
projection lock, and the answer is `200 {"version":1}` with `X-Qory-Configuration`. A run
through a gateway takes its outcome from its registering node's keys, as a direct run
does, never from the gateway's. The
outcome is not folded: a rebuild keeps it, and the fold applies it after every pass, so it
decides the run's state and reason whenever it arrives (How a run ends). An outcome spends
a token of the run endpoint's bucket of the key's rate, as a registration does.

**The rate.** A registration and a reload spend a token of the key's rate for the run
endpoint, a bucket separate from the events endpoint's, so a gateway flushing a
backlog of events still registers a new run: `429 {"error":"rate_limited"}` with
`Retry-After` beyond it. As a run opens, the gateway tries the registration up to 3 times,
the second try 1 second after the first ends and the third 2 seconds after the second,
none starting more than 6 seconds after the run was asked for (the contract, The gateway's
link: Tries as a run opens), with the same bytes each time. It asks again after no answer,
a `5xx` and a signed `429` `rate_limited`, and does not read `Retry-After`; every other
answer is final, and a run whose registration is refused on every try does not open.

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
| `429` `rate_limited` | yes | over the code's limit, with `Retry-After` |
| `409` `key_invalid` | yes | the ledger holds the key: another access key's, a revoked one included |
| `409` `key_limit` | yes | the node holds two keys |
| `201` | yes | the key is made, and active |

A signed answer is signed under `qory-enrol-answer-ed25519-v1`; its line 3 is the request's
`proof`, and its body lists `apiary_public_key`. The `201` carries `version`,
`access_key_id`, `node_id`, `node_kind`, `stored_secrets` and `apiary_public_key`. An
unsigned answer lists no key. A refusal changes nothing: the code stays outstanding.

A run code (`qecr_`, `Apiary.Runs.RunCode`), which a claim answers in place of its run's
run key, is answered in the same order, and the two `409`s of the ledger and the limit
never apply to it: no access key is made, and its public key enters no ledger. Its `401`
is also a code at or past its 15 minutes from the claim, a code of a run that has
ended (no longer pending or running, released, given its outcome, its events pruned, or
its run of the queue ended), a code whose registered run was deleted because its work
item was closed before its handover, and a code redeemed before by another public key. Its `201`
carries `version`, `run_id`, `run_key`, `apiary_public_key` and `documents`, in that
order, `documents` the run's documents as its claim encoded them (A run of the queue):
the run key is made at the
first redemption, its `issued` that time and its `attach_by` 600 seconds after, and the
run keeps it with the public key that redeemed the code and the timestamp of its proof.
A retry by the same public key, with a proof whose timestamp is newer than the one the
run keeps, is given the same `run_id`, `run_key` and `documents` again while the code's
15 minutes last, with `apiary_public_key` as the server's keys are at that moment, signed
over the retry's proof, and the run keeps the retry's timestamp in place of the one
before: the run keeps the timestamp of the newest accepted redemption. A proof with that
timestamp or an older one, the same retry sent again among them, is a replayed proof,
`401`, unsigned, and changes nothing.

A run code is redeemed only through the relay of the gateway the claim bound it to. The
relay signs the enrolment as a POST under the gateway's access key: `X-Qory-Access-Key-Id`,
`X-Qory-Instance-Id` and `X-Qory-Signature-Ed25519`, over the request string of
`qory-request-ed25519-v1`, the key id, the instance id, `POST`,
`/.well-known/qory-enrolment` as sent, and the raw body byte for byte, the lines joined
by a line feed and none after the body. The three headers are required, each once, the
instance id of the signed requests' form, and the signature verifies as a signed
request's (`ApiaryWeb.Contract.SignedRequest.relayed/1`) under a live key of the
gateway's node: any of its keys, so the key in use and the one that replaces it both
pass. A header missing or sent twice, a signature that does not verify, or a key of
another node, another gateway of the organisation among them, is the unknown code's
`401`, the same status, body and headers, checked before the proof and before the
code's state, and nothing is written: the code stays outstanding for the bound gateway.
The body's timestamp window, the single use and the retry stay as they are, and the
relay's signature adds no timestamp: a POST signs none. For any other code the three
headers are not read.

## The log and the terminal

`dev.qory.run.log` is stored like any event and its bytes, decoded, are the run's
`log_chunks`, one row a chunk, keyed by the event's sequence; `output.log` is their
concatenation in sequence order, which is what the log endpoint of the console streams. How
the session cuts the chunks is the session's affair and Qory Apiary reads nothing into a boundary:
on pipes a chunk is one line or 4096 bytes and may end inside a multibyte character, on a
pseudo-terminal it is one redraw, 4096 bytes or a quiet gap of 50 ms after the runtime's
last write, never inside a character. The terminal of the run page hands the bytes to
xterm.js as bytes, so a character cut in two is still one character.

The size of the pseudo-terminal is in the record: `terminal` of each
`dev.qory.session.started` (`cols`, `rows`, present exactly when `interactive` is true) and
one `dev.qory.run.resized` per change, at the sequence where the new size took effect, so
the chunks before it were written to the old size and the chunks after it to the new. A
session's start sets the size the same way for the chunks after it. The projection keeps
the size the record last said, `runs.terminal_cols` and `runs.terminal_rows`, the later
of the last session's start and the last resize by sequence; a resize whose data is not a
size (an integer in 1 to 65535 each) changes nothing. The run page's Details shows it. A
resize is not an item of the timeline: the terminal is where it matters.

The terminal tab replays at the recorded size. The bytes never cross the LiveView socket,
so the sequence of the sizes has to reach the reader beside the bytes: the log endpoint
answers one size at a time. `x-qory-log-size` (`<cols>x<rows>`) is the size in force right
after `after`: of the later of the last resize and the last session's start at or below
it, else of the run's first session's start, and absent inside a session on pipes. An
answer stops short of the next resize or the next session's start, and once every chunk
before it is sent, `x-qory-log-through` is that event's sequence, so the next question is
answered at the new size. The reader sets the screen to each answer's size before writing
its bytes, and xterm.js reflows as a terminal does. A resize that arrives after the chunks
past it (delivery is in any order) is applied on the next load, not to what is already on
the screen.

A run without a size is a run on pipes: the endpoint sends no size header and the page fits
the screen to the box, with the wrap toggle. On pipes `stream` is `stdout` or `stderr`, never
`terminal`, and a single stream of a pipes run, or a download, is never sized.

## What opened a run

Every run is opened once, by Forager's open of the run, before any session joins it.
`dev.qory.run.started` says so, in `opened_by`, which the contract requires and holds
to `run`, and carries the host, the wall where there is one, the labels and `about`. A
start whose `opened_by` is absent or anything else, `session` included, or that carries a
`credential` member, which the contract's schema refuses, is refused with its whole batch,
a signed `400` `invalid_request` (`Apiary.Runs.Batch`).

Each session that joins the run has a `dev.qory.session.started`, numbered from 1 in
`session`, with the runtime, the command, its arguments, the directory and whether it is
interactive, with the terminal's size and the image where they apply, and a
`dev.qory.session.exited`, how the session ended. A join that was refused has a
`dev.qory.session.exited` alone. Both types are stored like every other. The projection
reads the runtime, its version, the command, its arguments, the directory, whether it is
interactive and the image from the `dev.qory.session.started` with the highest sequence,
and folds nothing from `dev.qory.session.exited` (`Apiary.Runs.Fold`). The run's
`dev.qory.run.exited`, one per run, carries `state` and `exit_code`. A session's
`dev.qory.run.log`, `dev.qory.run.resized` and runtime events carry its number as
`session`, which is stored with the event; the projection reads nothing from it.

## The steps of a run

A step is one named unit of a run's host work or of a session's join, such as a fetch, a
compose, the fetch of an image or the start of a wall. Each step is a
`dev.qory.run.step_started`, with `step`, its number in the run from 1, `name` and
`kind`, then a `dev.qory.run.step_exited` with the same `step`, `state`, `exit_code` and
`duration_ms`; the step's log lines are the `dev.qory.run.log` events with its number as
`step`. Both types are stored like every other, and the projection folds them into
`run_steps`, one row per number of a run (`Apiary.Runs.Step`), and keeps each log chunk's
`step` (`Apiary.Runs.LogChunk`). `Apiary.Runs.Record.steps/2` reads a run's steps and
`Apiary.Runs.Record.step_log/4` the log lines of one.

What the projection reads:

- `step` is an integer from 1 to 2147483647; a step event whose `step` is anything else
  is stored and folded into nothing, and a log chunk with such a `step` has none.
- `name` is cut to 1024 bytes on a character boundary. `kind` is `fetch`, `compose`,
  `image`, `setup`, `join` or `wall`, and any other value is absent.
- The exit's `state` is `succeeded`, `failed` or `cancelled`; any other value, or none, is
  `failed`, as for a run's exit. `exit_code` outside -2147483647 to 2147483647 and a
  negative `duration_ms` are absent.
- A step is `running` from its start until its exit is folded.
- The contract writes each number once and one exit after its start. Should a run send
  two starts or two exits with one number, the one with the lower sequence decides, in any
  order of arrival; an exit folded before its start is kept, and the start fills the rest.
- A run the gateway ends during a step has no `dev.qory.run.step_exited` for it: Forager
  writes that exit in the session's record alone, which a server never receives. Once the
  run's `dev.qory.run.exited` is folded, every step of the run without an exit is
  `cancelled`, the contract's state of a step stopped before it ended, and keeps no exit
  code, duration or exit sequence. An exit that arrives after that sets the step's state
  as it says. A run that Qory marks lost without a `dev.qory.run.exited` leaves its open
  step `running`.

Retention deletes a run's steps with its events, and a step's log lines with the log
(`Apiary.Retention`).

A run through a gateway belongs to the node that registered it, with that node's instance
and key: a gateway is a separate kind of node, whose key is refused at registration
(`gateway_key`), and no gateway opens a run. The gateway that attached the run delivers its
events under the gateway's keys (`Apiary.Runs.Sender`), and the run's workspace, node
and instance stay the registration's. `host` is the machine the runtime runs on, so the
run's Node is the node that registered it and its Host that machine.

## How a run ends

Every `dev.qory.run.exited` carries `state`, how the run ended: `succeeded`, it ended well; `failed`, it ended badly;
`cancelled`, it was stopped before it said how it went. It may carry `reason`, why: an open
code, a lower-case letter and then up to 63 lower-case letters, digits and `_`
(`^[a-z][a-z0-9_]{0,63}$`, matched from `\A` to `\z`). Forager's codes are reserved:
`timeout`, `interrupted`, `no_session`, `stopped`, `session_lost`, `gateway_lost`,
`batch_refused`, `run_closed` and `image_missing`, and so are old names Forager no longer writes, which
records written before may hold: `quiet`, `credential_expired`, `credential_check_unreachable`,
`credential_check_invalid`, `run_ended_at_issuer`, `issuer_unreachable` and
`issuer_answer_invalid`. Any other code is the one the run's
starter gave, carried as given. Events are read as untrusted, so a `state` other than the
three, or a `reason` that breaks the pattern, is read as absent (`Apiary.Runs.Fold`).

A run is in one of six states, in four families (`Apiary.Runs.Run.states/0`,
`Apiary.Runs.Filters.families/0`):

| State | Word | Family | Final |
|---|---|---|---|
| `pending` | Pending | Alive | no |
| `running` | Running | Alive | no |
| `completed` | Completed | Ended well | yes |
| `cancelled` | Cancelled | Cancelled | yes |
| `failed` | Failed | Ended badly | yes |
| `lost` | Lost | Ended badly | from an exit, yes; from the lost-run check, no (Liveness) |

The fold maps an exit to a state by the first rule that applies
(`Apiary.Runs.Fold.exit_state/2`):

1. `failed` with `session_lost` or `gateway_lost` is Lost: nobody knows how the run ended.
   An exit came, so the state is final, and `lost_at` is the exit's time: no start or
   heartbeat folded after it revives the run.
2. `state` decides: `succeeded` is Completed, `failed` Failed and `cancelled` Cancelled.
3. Without a `state`, which the contract requires, `session_lost` and `gateway_lost` are
   Lost, and any other reason, or none, Failed.

A run whose `dev.qory.run.refused` reaches Qory Apiary did not start: it is Failed, with the
refusal's `code` as its reason and no exit time. For a code of a check of the run's
settings on the machine (`run_configuration_invalid`, `tool_unknown`, `image_unknown`,
`image_not_allowed`, `image_user_root`, `variable_reserved`, `placeholder_conflict`,
`mount_mode_conflict` and `mount_contains_forager_files`) its page says "The run's settings
did not pass a check on the machine (image_unknown).". For `engine_unreachable` it says "The
machine could not check an earlier run's container (engine_unreachable).", and for any other
code "did not start" with the code ("did not start: image_missing"). An exit decides over the refusal, in whichever order the
two are folded; no start or heartbeat folded after either changes the state. The refusal's
time is kept as `refused_at`, nil once an exit decides over it; the starter's outcome
leaves it as it is.

Forager's codes, and the words Qory Apiary says for each
(`ApiaryWeb.RunComponents.reason_words/1`):

| `reason` | What Qory saw | State | Words |
|---|---|---|---|
| `timeout` | the run's time limit was reached, and the session stopped the runtime | Cancelled | time limit reached |
| `stopped` | the run was stopped, and its starter gave no outcome | Cancelled | stopped, no outcome given |
| `interrupted` | a session's run was stopped from where it was started (a Ctrl-C, or a signal to `qory run`) before its program ended by itself, and neither the run's starter, the gateway nor the time limit had ended it first | Cancelled | interrupted |
| `session_lost` | the gateway heard nothing from the session for three of its heartbeat intervals | Lost | stopped responding |
| `gateway_lost` | the gateway was lost before the run's exit was recorded; the exit is written when the record is sent again | Lost | end not recorded |
| `batch_refused` | the gateway refused a batch of the session's, and ended the run | Failed | events refused |
| `run_closed` | nothing: the session's record alone holds it, the gateway's `410` to a run already ended there | by its `state` | none |
| `no_session` | the run was closed with no session started, after its host work failed, such as a fetch or a compose; `exit_code` is `-1` | Failed | no session: the code, its `_` read as a space |

A record written before may hold an old name, read in these words:

| Old `reason` | Words | State |
|---|---|---|
| `credential_expired` | permission to run expired | by its `state` |
| `credential_check_unreachable` | couldn't check whether the run may go on: no answer | Failed |
| `credential_check_invalid` | couldn't check whether the run may go on: unreadable answer | Failed |

`quiet` reads as given: "quiet". `stopped` beside Completed or Failed, which Forager does
not write, reads "stopped". `interrupted` comes only with `cancelled`, in the exit the session writes: a local
link's record holds it, and a gateway's holds the same exit, which it accepted from the
session and never writes itself. The exit's code and signal are as the session observed
them: exit 0 when the program shut down cleanly on the signal, 130 from a SIGINT, or
a signal such as SIGTERM when the session stopped it. The run is Cancelled whatever they
are, and the session run's Exit shows them as recorded.

An exit stored under an old name reads in the words of its new one: `run_ended_at_issuer` as
`stopped`, "stopped, no outcome given" whatever its state; `issuer_unreachable` as
`credential_check_unreachable`; `issuer_answer_invalid` as `credential_check_invalid`. A
refusal's code under an old name is shown under its new one.

Any other code is the starter's, and Qory Apiary keeps no list of them: it is shown as
given, with spaces for underscores. `all_checks_passed` beside Completed reads "all checks
passed", `checks_failed` beside Failed "checks failed", `no_longer_needed` beside Cancelled
"no longer needed".

The words stand after the state in the run page's meta line, under State in its Details
rail, in its timeline's last item, after the state in the runs list's preview, and in what
the page announces when a run is cancelled or ends Lost ([ui.md](ui.md), The run page).
The timeline's last item says the exit's reason: for a run given an outcome, whose
reason is the outcome's, it can differ from the others.

A session's run carries `exit_code`: the runtime's exit status, with `signal` when one
killed it, and `-1` with `gateway_lost` and in every exit the gateway writes for it, which
holds no exit status of the runtime's. A record written before may hold an exit with no
`exit_code`, of a run with no process. The rail's Exit
row shows the value as recorded, whatever the state: the signal, else the code, and "not
recorded" for `-1` without a signal. The state comes from `state` and `reason`, never from
the exit code: a run its starter judged a failure can show Exit 0.

The check on `runs.state` refuses any value but the six states.

A run's starter may give its outcome (The run endpoint). It is stored on the run, not
folded, and it sets the run's state and reason whenever it arrives, before the exit or
after it: `succeeded` is Completed, `failed` Failed, `cancelled` Cancelled, and the run is
not lost (`Apiary.Runs.Fold.outcome/1`). The exit's state and reason are kept beside it
as `exit_state` and `exit_reason`, with its exit code and signal. A rebuild gives the same
run, since the fold applies the outcome after every pass and a rebuild's reset starts from
it. Where the outcome's state differs from the exit's, the run page says both: "Succeeded,
as its starter said; the runtime exited 1". A run refused at its start (`refused_at`)
never started a runtime: it says the outcome's state alone, "Succeeded, as its starter
said". An outcome sent with no state,
stored as Cancelled with the reason `stopped`, has no such sentence: the run reads as any
Cancelled run, with the words "the starter gave no outcome"; the `stopped` Forager writes, with
no outcome, keeps "stopped, no outcome given".

Qory Apiary records what a run reports and starts no run. Once a run's starter has given
its outcome, until the run's `dev.qory.run.exited` arrives, each signed `2xx` to its
batches carries `end` with the outcome's state and reason (Signed POST: the events
endpoint). A run ends by its runtime's exit or at the gateway.

## Liveness

A run is alive from its registration until its `dev.qory.run.exited` or its
`dev.qory.run.refused`, or until it goes silent. Qory Apiary's lost-run check
(`Apiary.Runs.Liveness`) marks a run `lost` when nothing has been heard of it for more than
three of its heartbeat intervals: the `interval_seconds` its registration stated, or for a
run through a gateway its attach, else its heartbeats', else 30 seconds, so 90 seconds in
all. A `running` run is measured from its last heartbeat, else from the arrival of its
`run.started`, and a `pending` run from its attach, for a run through a gateway, else from
when the workspace first heard of it, its registration for a run that registered. A run
through a gateway that is never attached is lost at its `attach_by`, and not before; until
then it holds its node's instance. A run a workspace's queue handed over is also lost at
its backstop, which its attach sets to the attach and its step's limit, 87,300 seconds for
`explore` and 4500 for `prebuild` (`runs.backstop_at`), should it have no exit by then,
however recently it beat; no heartbeat or start that arrives after that brings it back,
and only its exit changes its state: a run of the queue takes no outcome. A run of the
queue that went 600 seconds without a heartbeat after its attach, before an exit, has its
backstop moved back to the end of that silence when the lost-run check ends its dispatch,
so it is lost from then on in the same way. A heartbeat
counts by the `time` it carries, corrected by the run's clock offset (the smallest arrival less
`time` over the run's heartbeats), plus 300 seconds, and never after its arrival, as the
contract's liveness for the server says; a run's first heartbeat with no offset before it
counts at its arrival. Only the server's clock is compared.

Every event of a run reaches the server from one gateway: Forager's gateway on the node,
under the node's keys, for a run that goes directly, or the gateway that attached it,
for a run through a gateway; a session's heartbeats come through it. So `lost`
means the gateway sent nothing recent for the run. A session that falls silent is the
gateway's to notice, and it ends the run `failed` with `session_lost`, an exit the server
reads as Lost, and final (How a run ends). The lost-run check's `lost` is not final: a
later heartbeat that counts within three intervals of its arrival brings the run back,
and the run's `dev.qory.run.exited` decides its state by How a run ends. For a run
through a gateway, after a loss, only the attaching instance's heartbeat makes the run
live again: each event is stored with the instance id of the request that delivered it
(`events.node_instance_id`), and the fold counts the starts and heartbeats of the instance
that attached the run alone (`Apiary.Runs.Fold.liveness_instance/1`). Another instance's
heartbeat is stored and answered, and moves neither the run's state, nor `lost_at`, nor
its last heartbeat, and a rebuild folds it the same. An event stored before its instance
was kept, and every event of a run whose attaching instance is not known, count as any
heartbeat does. An exit `failed`
with `gateway_lost`, sent later with the run's record, or with `session_lost` keeps the
run Lost, now final, with `lost_at` the exit's time; any other exit sets the state it maps
to.

**After an outage.** A gateway that could not reach the server keeps the run's record and
sends it once the server answers again, oldest first. Its heartbeats arrive late, and each
counts by the `time` it carries, so the record reads as it happened: a run that ended during the
outage stays `lost` until its `dev.qory.run.exited` arrives, and a run still alive runs
again once one of its recent heartbeats arrives, one that counts within three intervals of
its arrival. The access key's last heartbeat is the latest time its runs' heartbeats count
at (the events endpoint, above), never later than their arrival, so a backlog's old
heartbeats do not move it to the backlog's arrival. A run that a backlog's old heartbeats
would hold alive is not counted alive and holds no instance of its node
(`Apiary.Runs.Liveness.alive/2`). Every event of the record is stored however late it
arrives, and a lost run is kept from retention for 7 days after it was lost (the events
endpoint, above). Three limits stay, by the 300 seconds and three intervals, 90 seconds at
Forager's default of 30:

- A heartbeat that arrives within 300 seconds and three intervals of the `time` it carries,
  corrected, still brings a run back, for at most three intervals after its arrival,
  until the next check after them. So after an outage shorter than 390 seconds at
  30-second intervals, a run that ended during it can be alive again for up to 90
  seconds.
- A session's run whose heartbeats all arrive late, because the outage began before its
  first one, has no offset before them: its first heartbeat counts at its arrival and sets
  an offset as late as the backlog, so the run runs again while its heartbeats arrive,
  until its `dev.qory.run.exited` arrives or three intervals after the last of them.
- A run whose machine's clock ran ahead and was then set back keeps the offset the clock
  ahead gave, the smallest, so each heartbeat after it counts the clock's lead less 300
  seconds before its arrival. More than 300 seconds and two intervals ahead, 360 seconds
  at 30, the run is found lost between its heartbeats; more than 300 seconds and three,
  390, no heartbeat brings it back, and it reads `lost` until its `dev.qory.run.exited`
  arrives.

## Failure

Every failure of authentication is `401` with the body `{"error":"unauthorized"}` and
nothing else, unsigned, whether the cause is a missing or empty `X-Qory-Access-Key-Id` or
`X-Qory-Signature-Ed25519`, a key id that is not of the exact form `ak_` and 16 lowercase
Crockford base32 characters (including one that is not valid UTF-8; such a value is refused
before any lookup), a key id that does not exist, a revoked key, a key of a node that was
deleted, a key whose row does not match its integrity code, a signature that is not 64
bytes of base64url or does not verify, or, after the version's `400`, a GET's timestamp
that is not an integer or is outside the window, or, after the body's `400`, a
registration's `time` outside it. The body
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
- The public base URL of the document comes from the application's URL configuration,
  not from the request's `Host` header.
- On every signed endpoint, a `X-Qory-Contract-Version` that is not the integer `1`
  (absent, another number, not a number, sent twice) is `400` with the versions served,
  once the request has verified, after the `429` and the instance id's `400`. At
  enrolment the header is read before the code, unsigned: sent twice it is `400`
  `bad_request`, and any other value that is not `1` is `400` with the versions served,
  after the per-address `429`.
- The body limit is 2 MiB for a batch, twice the mebibyte the gateway cuts a batch at, and
  64 KiB for a registration; it is checked before the signature.
- The rate limit is per access key and per node: 50 batches a second, 100 at once
  (`config :apiary, Apiary.Runs.RateLimit, rate: 50, burst: 100`). Every request that passed
  the `413`, the `415`, the `400` of a header sent twice and the `401` spends a token,
  whatever it is answered after that: a `400`, a `409` and a `410` count like a `202`, so a
  key that keeps sending what is refused is slowed like any other. What is refused before,
  and so an unauthenticated request, spends nothing. Discovery spends none. A run's
  registration and its reloads spend a separate bucket, per access key and per node,
  the same 50 a second and 100 at once
  (`config :apiary, ApiaryWeb.Contract.RegistrationController, rate: 50, burst: 100`): a
  gateway registers a run as it opens, within its tries, and reloads it on a new digest,
  and a flush of events never spends it.
- A batch holds at most 1000 events, `data` nests at most 64 levels, `time` is in the years
  1970 to 9999, and `sequence` starts at `0000000001`; anything else is `400`
  `invalid_request`.
- Events are stored as received and unknown types are kept. The one exception: a NUL
  character inside `data`, which Postgres cannot hold, is stored as U+FFFD; a `type` with one
  is not a batch.
- `time` may carry any RFC 3339 offset and is stored in UTC, to the microsecond.
- `X-Qory-Delivery` that is absent or not a UUID does not fail the delivery: the batch is
  stored and its delivery is recorded with no delivery id (null), so such a delivery is
  deduplicated by event id only.
- `X-Qory-Timestamp` sent twice on a POST is `400` `bad_request`, as on a GET, though a
  POST's timestamp is not read.
- A `POST` answers `503 {"error":"unavailable"}` when the database refuses the batch or
  cannot be reached: the transaction is rolled back, the log names the kind of the failure and
  nothing of the batch, and no `X-Qory-Configuration` is sent. The gateway retries anything that
  is not `2xx` or `410`.
- The path is matched after percent-decoding, as the router matches it: `/v1/%65vents` is the
  events endpoint, signed and verified like it.
- The run endpoint never answers `304`, whatever `If-None-Match` says: to the gateway any
  answer to a registration but `200` is no run, a `5xx` or a `429` once its tries are
  spent, and any answer to a reload but `200` a reload that failed. The `ETag` is there
  for a person with `curl`.
- A label that names a target (`forge` or `repository` in the software domain) names one
  when it is a string of valid UTF-8, not empty, at most 256 bytes, with no control character: C0, DEL, C1 (U+0085 among them),
  U+2028 and U+2029, anything that ends a line somewhere. A label that fails this is neither
  cleaned nor cut, since either would file the run under a target it did not name. The
  run is kept with its labels as sent, belongs to no target (the console lists it as
  unassigned), and is served the workspace's baseline. One function decides this for the
  projector, which makes targets from the labels of `run.started`, and for the wire, so
  a registration, a reload and the digest in an answer always pick the same target as
  the projector, or none. On the wire the labels are the registration's, compared to the
  stored ones byte for byte; labels the contract's rules refuse are `400
  invalid_request`, and a target's label that passes them but cannot name a
  target, one with a control character, is the baseline and not an error. Nothing of
  the labels is logged.
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
  1 to 256 bytes, is dropped alone; its `title` (1 to 256 bytes) and `url` (at most
  2048 bytes) are dropped from it alone when they break theirs. A `url` is kept only when it
  is absolute `http` or `https` with a host and no user name or password. Subjects are
  de-duplicated by type and ref, the first kept, and more than 16 are cut to the first 16.
  Forager refuses a run whose `about` breaks any of these; the fold drops the part that
  breaks one, for whatever reaches it. A type is shown as given: Qory Apiary knows no
  subject types. A later `run.started` replaces all of it, like every other field. A run's
  title is its `about` title; without one, the run page's heading says `Run` and its whole
  `rn_` id, its breadcrumb and title `Run` and its short id, the lists the short id, and
  the Overview its command line, else its short id. The
  registration carries `about` beside the labels, held to these rules whole
  (`Apiary.Runs.About.validate/1`: a registration whose `about` breaks one is
  `400 invalid_request`), and kept on the run as `registration_about`. It never selects a
  policy: the policy is chosen by the registration's labels.
- An exit without a `state`, which the contract requires, is Lost with the reason
  `session_lost` or `gateway_lost`, and Failed with any other reason, or none
  (`Apiary.Runs.Fold.exit_state/2`).
- When the run configuration cannot be read, a registration is answered `503
  {"error":"unavailable"}` and nothing is stored, which the gateway asks again within its
  tries as a run opens (The run endpoint, above). To the last try it is no run: the run
  fails closed, as it does on any answer but `200`. A managed workspace is never answered
  `{"version":1}` for a read that failed, which would start the run without its policy.
- The digests in an answer to a batch are read after the commit, never rendered: one read
  that says whether the workspace's policy is managed (an index on `run_configurations`),
  then, for a managed workspace, the newest configuration of the run's target (one
  read of an index), and the baseline's after it when the target has none;
  while the run's target is not known yet, a lookup of the target by its labels or
  of the reported digest comes before. Three to four small reads, not one. If a read fails
  the header it decides is absent, which means nothing to the gateway, and the delivery is
  still `202`.
- A run that registered is answered the digest for the target its registration's
  labels name, the baseline's when they name none, whatever its events say
  (`Apiary.Policy.Serving.digest_for/4`). A run that did not register has its target
  known to the server once its `run.started` is projected, which is after the receiver
  answers. Until then the answer's digest is, in this order: that of the target the
  batch's `run.started` labels name; else, when the request's
  `X-Qory-Run-Configuration` is a digest in force in the workspace (the baseline's newest,
  or any target's newest), that digest; else the baseline's. A gateway told a digest it
  does not hold reloads once and remembers the answer it tried, so the worst case is one
  reload that changes nothing.
- The `cost_usd` of `dev.qory.runtime.result` is the runtime's total for the session:
  what Claude Code prints as `total_cost_usd` in its result line, which counts the tokens of
  the subagents the session ran as well as the session's. `dev.qory.runtime.subagent_finished`
  carries no cost. So Qory Apiary folds a run's cost as the sum of `cost_usd` over the run's
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
  the contract). The policy in force in a run's Details reads it whole, cut only past
  4096 code points; the timeline's policy applied item reads a tool's cut at 256
  (`Apiary.Runs.Record.Timeline.max_argument/0`), and its one-line summary shows the first 64 of them, with the 256 in the argument's title. A
  cut argument ends in `…`. Lengths are code points, as the schemas' `maxLength` and the
  database's `left` count them, in the query and in `Timeline.slim/1` alike. The event
  lists each use of a credential, all with the same name and argument; Details
  shows them as one entry with the hosts of every use. It reads the first twenty uses and
  the first twenty tools, and counts the different names and arguments among all of them,
  so "and N more" is the number of entries, grouped, that it does not show. The vendored
  policy schema at the pinned ref also lets a policy select `tools` and an `image`, which
  Qory Apiary does not render; the tests of tool invocations and of arguments use separate
  fixtures beside the contract's.
- What the gateway does with the policy document, read from `gateway/internal/proxy`,
  `policy` and `session` of Forager at the pinned ref, and what Qory Apiary
  renders for it:
  - A connection whose host equals an entry of `egress.allow_first` is allowed first, in
    either mode. Any other connection is decided by `egress.deny`
    (`Proxy.decide`), in either mode and with the first matching deny entry as the rule,
    then by `egress.allow` and the mode. Only a connection that was allowed is
    terminated and held to `egress.paths`. A host that is only in `paths` is denied under
    `enforce`. So a host held to paths is rendered in **both** `allow` and `paths`, or,
    for an integration's host, in `allow_first` and `paths`, and a denied host is never
    in `paths`: it is never reached.
  - A host several keys of `paths` cover is held to the most specific one: its name
    itself, else the `*.` key with the longest suffix (`policy.HostPaths`). A `*.` key of
    `paths` also holds every allowed host below it that no more specific key names. Qory
    Apiary still refuses, at write time and with a sentence, a `*.` suffix held to paths
    above any other allowed entry; a name held to paths under a `*.` suffix that is free of
    paths is fine and rendered.
  - `deny` beats `allow` whatever the shapes, so a deny of a host below an allowed `*.`
    suffix is said as it is: `allow: ["*.example"]`, `deny: ["tracker.example"]`. A `*.`
    deny still takes the allow entries it covers out of `allow` (the gateway would deny
    those hosts by the deny anyway), so the document lists what is reachable and nothing
    else, and a policy's count of hosts allowed is the truth. The one shape the document
    cannot say is a `*.` deny with an allow below it that outranks the deny (the workspace's
    unlocked `*.example`, a target's rule allowing `api.example`): the allow wins by precedence
    and is rendered, and the deny is not written to `deny`, since an entry there would
    deny the winning host too; it still takes out the allow entries it outranks, so under
    `enforce` those hosts are denied by having no allow, and under `observe` they are
    reached and recorded with no rule (`Apiary.Policy.Resolution`). Nothing is ever
    rendered that allows more than the page shows, or denies what the page says is
    allowed.
  - A policy with `paths` or `credentials` needs a wall: without one Forager refuses to
    start the run, in either mode, and on a reload it takes the hosts held to paths out of
    `allow` and refuses a configuration that selects credentials. Qory Apiary renders what
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
- Enrolment through a gateway: the gateway relays the body unchanged (the Forager
  contract's relay), strips `X-Forwarded-For`, `Forwarded` and `X-Real-Ip`, and signs the
  request under its access key, so it arrives from the gateway's address, which
  `ApiaryWeb.Origin` gives as any peer's. A node's code is accepted as a direct one, with
  no check of which gateway relayed it: the code decides the node, and the relay's
  headers are not read. A run code is redeemed only through the gateway the claim bound
  it to (Enrolment). The signed answer is bound to the machine's `proof`, which the
  gateway passes back unchanged. Every machine behind one gateway shares that address's limit, 1
  a second and 10 at once, which is not raised for a gateway's address, and the audit
  entry of the key's arrival records the gateway's address as `remote_ip`.
