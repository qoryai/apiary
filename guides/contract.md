# The server contract

The server contract is what Forager and a server say to each other: how Forager's gateway
finds the server's endpoints, how a machine enrols its access key, how a request proves
which key it holds, how a run registers before it starts, and how the gateway delivers a
run's events.
<!-- feature: security -->
It is also how a run is given its security policy.
<!-- /feature -->
Qory Apiary implements the server's side. A receiver of your own that implements the same
contract works with Forager the same way.

## Where the contract lives

The contract is not in this repository. It is the `contracts/forager/v1` directory of
Forager's repository: a README that defines every document and header, one JSON schema per
document, and fixtures, among them signed requests with the status a receiver has to answer.
Qory Apiary implements version 1, revision 1, tool invocations included: the `tools` of
`dev.qory.run.policy_applied`, and the `tool`, `request_id` and `status` of
`dev.qory.run.egress`.
<!-- feature: security -->
[Tool invocations](security-policy.md#tool-invocations) says what they are.
<!-- /feature -->
A run opens with its registration (below). A Forager that opens a run with a ping,
`dev.qory.ping`, is refused, and the run does not start: run Forager and Qory Apiary of the
same release.

Where this page and the contract disagree, the contract wins. Two files in the server's
repository tie the two together:

- `.forager-contract-ref` pins the ref of Forager's repository whose fixtures the server's
  tests replay, in development and in CI: the known answers of its signatures, the batches,
  and a recorded run in any order, batching and repetition.
- `docs/contract-assumptions.md` is the server's full reading of the contract, with
  everything the contract has not fixed and the server chose, under "Assumed". This page is
  a summary of it.

<!-- feature: security -->
The contract's schemas for the run configuration and the policy are vendored in the server,
and every run configuration is validated against them before it is stored.
<!-- /feature -->

## Who is asking: the access key

Every request names a node's access key, an Ed25519 key, and is signed with that key's
secret, which never leaves the machine: the server holds the public key alone. The key
decides the workspace and the node: a run is stored in the workspace of the key that
registered it, on the key's node or node pool.
<!-- feature: security -->
A run configuration is the one of the key's workspace.
<!-- /feature -->

On every request:

| Header | Value |
|---|---|
| `X-Qory-Access-Key-Id` | the key id, `ak_` and 16 lower-case Crockford base32 characters |
| `X-Qory-Instance-Id` | the instance id, `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`: which running copy of Forager is asking |
| `X-Qory-Instance-Name` | the instance's display name, unsigned, for display alone |
| `X-Qory-Contract-Version` | the revision Forager implements, `1` |
| `X-Qory-Signature-Ed25519` | the Ed25519 signature of the request string, 64 bytes in base64url without padding |
| `User-Agent` | `qory-forager/<version>` |

The server serves revision 1 of contract v1 and nothing else. On every endpoint, a request
that verifies but whose `X-Qory-Contract-Version` is not `1`, absent or sent twice included,
is answered `400` with `{"error":"unsupported_contract_version","supported":[1]}`, and
nothing is served. A request that does not verify is `401` whatever the header says.

The server records Forager's version and the contract version on the key, and each
instance it hears from on the key's node. Forager's version never decides the answer.

## Signed requests

**The request string** is six lines joined by a line feed, with none after the last:
`qory-request-ed25519-v1`; the access key id and the instance id, exactly as their headers
carry them, an absent instance id as an empty line; the method, in upper case; the request
target exactly as sent, the path, then `?` and the query only when the query is not empty,
nothing decoded, re-ordered or normalised on either side; and last, for a GET the value of
`X-Qory-Timestamp` as sent, for a POST the raw request body.

```text
qory-request-ed25519-v1
ak_f1xt0re000000000
i_gYKDhIWGh4iJiouMjY6PkA
GET
/.well-known/qory-configuration
1700000000
```

The contract's known answers for these strings are in its
`fixtures/known-answers/signatures.json`.

### A signed GET

For the configuration document and a run's reload. It carries `X-Qory-Timestamp`, Unix
seconds, UTC, a decimal integer.

**The five-minute window.** The server accepts the request when its own clock and the
timestamp differ by at most 300 seconds, earlier or later alike. A run's registration
carries its own `time`, held to the same window. A machine whose clock is more than five
minutes wrong is refused, so keep the clocks of the server and of the machines
synchronised.

### A signed POST

For a run's registration and for the events endpoint. A registration carries
`Content-Type: application/json`, and its body says when it was built (below). A batch
carries:

| Header | Value |
|---|---|
| `Content-Type` | `application/cloudevents-batch+json` |
| `X-Qory-Delivery` | a UUID per batch; a retry of the batch carries the same one |
<!-- feature: security -->
| `X-Qory-Run-Configuration` | optional: the digest of the run configuration the run holds |
<!-- /feature -->

No timestamp line is signed: a replayed batch is a duplicate, which the server discards by
event id, and a registration's `time` is in its signed body. The signature covers the path
and the body, so a body signed for one endpoint fails at every other, and it is verified
over the bytes as received, before anything parses them.

### Signed answers

Every answer to a request that verified is signed with the server's own Ed25519 key, the
key every machine pins as `apiary_public_key`: `X-Qory-Signature-Ed25519` over the answer's
status, the request's signature, the SHA-256 of the body, and the answer's
`X-Qory-Configuration` and `X-Qory-Run-Configuration`, with
`Cache-Control: no-store, no-transform`. The signed string starts with the line
`qory-answer-ed25519-v1`. The gateway treats an answer without a valid signature as no answer.
Every `401` goes out unsigned, and so does a refusal before the request is verified (`413`,
`415`, a header sent twice). An answer to an enrolment is signed under its own first line,
`qory-enrol-answer-ed25519-v1`, with the request's `proof` in place of a signature, so
neither kind of answer can pass for the other (below).

### Refusals, in order

On every endpoint, the first refusal that applies is the answer:

1. `413`, a body over 64 KiB (a registration) or 2 MiB (the events endpoint);
2. `415`, a content type other than `application/json` (a registration) or
   `application/cloudevents-batch+json` (the events endpoint);
3. `400` `bad_request`, unsigned, for `X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`,
   `X-Qory-Signature-Ed25519` or `X-Qory-Timestamp` sent twice;
4. `401`, any failure of authentication (below);
5. `429` `rate_limited`, the key's rate is spent (the events endpoint, and a run's
   registration and reload, each from a bucket of its own);
6. `400` `bad_request`, signed, an instance id absent or outside its pattern;
7. `400` `unsupported_contract_version`;
8. `400` `invalid_request`, a body the contract refuses (a registration, the events
   endpoint);
9. `401`, a GET's timestamp that is not an integer or is outside the window, or a
   registration's `time` outside it;
10. then each endpoint's own.

A refusal after verification is `application/json`, `{"error":"<code>"}`, signed.

### Failure

Every failure of authentication is `401` with the body `{"error":"unauthorized"}` and
nothing more, unsigned: a key id or signature missing or empty, a key id of the wrong shape,
a key the server does not know, has revoked, or that is no node's, a signature that does
not verify, a stale timestamp or registration `time`. The body never says which, and
nothing about the request's headers is logged. The key is looked up only after its shape is checked, and the signature
is verified cofactorless, as RFC 8032 defines it.

## The endpoints

### Discovery: `GET /.well-known/qory-configuration`

A signed GET. The answer is `200`, `application/json`, with the header
`X-Qory-Configuration: sha256=<hex>`, the SHA-256 of the body as sent. A contract version
other than `1` is `400 unsupported_contract_version`, as on every endpoint.

```json
{
  "version": 1,
  "node_id": "nd_f1xt0re000000000",
  "events": {"url": "https://qory.example/v1/events", "types": ["*"]},
  "run": {"url": "https://qory.example/v1/runs"},
  "apiary_public_key": [{"alg": "ed25519", "public_key": "rcFAEfgtHFbZVqpPnXPYhYNhpgYEhSXg0Ixjjcdd2Mc"}]
}
```

`node_id` is the key's node or node pool, and `apiary_public_key` lists the server's
signing key, for information: the gateway verifies under the key it pinned. `run.url` is
the run endpoint, with no trailing slash: a run registers there, and a reload adds `/` and
the run's id. The document, and its digest, differ by node and by nothing else.

The URLs are built from the server's `PUBLIC_URL`, never from the request's `Host` header
([Install and configure](install.md)). A Forager file's `gateway.server.url` is that address, and the
gateway finds the other endpoints through this document alone.

### A run's registration: `POST /v1/runs`

A signed POST, `Content-Type: application/json`, before the run starts. The body is the
contract's `run-registration.schema.json`:

```json
{"version": 1,
 "run_id": "0192f0c1-7d4e-7a2b-8c3d-4e5f6a7b8c9d",
 "labels": {"forge": "git.example", "issue": "77", "repository": "acme/shop"},
 "about": {"title": "Fix the failing build"},
 "forager_version": "0.7.0",
 "contract_version": 1,
 "interval_seconds": 30,
 "events": ["*"],
 "time": "2026-10-10T12:00:00Z"}
```

`version` is `1`; `run_id` is the run's id, a lower-case UUID; `forager_version`,
`contract_version`, `interval_seconds` and `events` are what the gateway announces for the
run, the heartbeat interval from 1 to 300 seconds; `time` is when the gateway built the
body, in UTC, to the whole second, ending in `Z`. All of them are required. `labels`, at
most 16, each value at most 256 bytes, and `about`, what the run is about as
`dev.qory.run.started` carries it, may be left out. The body is read strictly: a member
the contract does not name, or one that breaks its rule, is `400 invalid_request`. A
`time` more than 300 seconds from the server's clock is `401`.

The answers, in order; the first that applies is the answer:

| Status | When | Body |
|---|---|---|
| `413` | the body is over 64 KiB, or cannot be read | `{"error":"payload_too_large"}` |
| `415` | the content type is not `application/json` | `{"error":"unsupported_media_type"}` |
| `400` | a header the signature depends on is sent twice | `{"error":"bad_request"}` |
| `401` | any failure of authentication | `{"error":"unauthorized"}` |
| `429` | the key's rate for registrations is spent; `Retry-After` says how many seconds to wait | `{"error":"rate_limited"}` |
| `400` | the instance id is absent or outside its pattern | `{"error":"bad_request"}` |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included | `{"error":"unsupported_contract_version","supported":[1]}` |
| `400` | the body is not a registration, or breaks a rule | `{"error":"invalid_request"}` |
| `401` | `time` is more than 300 seconds from the server's clock | `{"error":"unauthorized"}` |
| `404` | the key may not open a run (`run.post_events`) | `{"error":"not_found"}` |
| `200` | a repeat: the same bytes again, under the same access key | the answer the registration was given |
| `410` | retention has pruned the run's events | empty |
| `409` | a new instance beyond its node's instance limit; the node counts the start refused | `{"error":"instance_limit"}` |
| `409` | the run id is taken: registered with other bytes or under another access key, or holding events that came without a registration | `{"error":"run_id_used"}` |
| `503` | the run configuration could not be read, or the run could not be stored | `{"error":"unavailable"}` |
| `200` | registered | the run configuration |

No run is stored on any refusal. A node runs one instance at a time, and a node pool up to
its instance limit: an instance counts while one of its runs is live.

The gateway builds the body once and sends the same bytes on every try, `time` included.
It tries up to 3 times as a run opens, 1 second and then 2 seconds after the try before
ends, none more than 6 seconds after the run was asked for: again after no answer, a `5xx`
or a signed `429`, whose `Retry-After` it does not read. A run whose registration is
refused on every try does not open. A repeat is given the answer it was given the first
time, and nothing is stored again. Once that run configuration is gone, because its
repository was deleted, the repeat is given the configuration in force now for its labels.

A `200` carries `X-Qory-Run-Configuration: sha256=<hex>` and `ETag` with the same string
quoted, always, and `Cache-Control: no-store, no-transform`. Its body is the run's run
configuration. `{"version":1}` is the run configuration of no policy: the run keeps the
policy of its machine's own Forager file.

The run is stored `pending`, on the key's node and the instance the request claimed, with
the labels, `about` and heartbeat interval of its registration. Its `run.started` moves it
to running. It is found lost when nothing is heard of it for three of the intervals it
registered with, 90 seconds at Forager's 30. The labels name what the run works on;
`about` is for display and never selects a policy.

<!-- feature: security -->
For a workspace whose policy somebody has made, the body is the workspace's run
configuration for the repository the registration's labels name:

```json
{"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["api.example"]}}}
```

The server reads the repository from two labels, `forge` and `repository`
(`Apiary.Lingo.Domain.Software`). Any other label names nothing. A repository the
workspace does not know, or labels that name none, or one label of the two, get the
workspace's baseline. The labels are compared to the stored ones byte for byte. The body
is the bytes that were stored when the policy was last changed. Nothing is rendered for a
request, so the digest is of exactly what is sent.

A workspace nobody has given a policy, or one without the `security` feature, is answered
`{"version":1}`, and its machines run under the policy of their own Forager file
([The security policy](security-policy.md)).

The gateway applies the `security_policy` narrowed by the machine's own `egress`; the
machine only takes away.
When the policy has deny rules its `egress` carries `deny` after `allow`, the hosts the
gateway denies first and in either mode; without any, the section is as above.
<!-- /feature -->

### The reload: `GET /v1/runs/<run_id>`

A signed GET, with `X-Qory-Timestamp`: the run endpoint, a slash and the run's id. The
gateway sends it when an answer carries an `X-Qory-Run-Configuration` other than the one
it holds. Its `200` has the same headers as the registration's, and its body is the run
configuration in force now for the labels the run registered with.

| Status | When | Body |
|---|---|---|
| `200` | the workspace has a policy | the run configuration |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included; or the instance id is absent or outside its pattern, or a header the signature depends on is sent twice | `{"error":"unsupported_contract_version","supported":[1]}`, `{"error":"bad_request"}` |
| `401` | any failure of authentication | `{"error":"unauthorized"}` |
| `404` | the run is not one this access key registered, an unknown run id among them; or the workspace serves no run configuration | `{"error":"not_found"}` |
| `429` | the key's rate for registrations is spent, which reloads share; with `Retry-After` | `{"error":"rate_limited"}` |
| `503` | the configuration could not be read | `{"error":"unavailable"}` |

The reload is answered only to the access key that registered the run. To the gateway any
answer but `200` is a reload that failed: the policy in force stays, and it tries again on
the next answer. The endpoint never answers `304`.

<!-- feature: security -->
A reload on a workspace with no policy, or a policy removed mid-run, answers `404`. A
policy removed mid-run never loosens a run that's already started, and the next run gets
the new state when it registers.
<!-- /feature -->

### Events: `POST /v1/events`

A signed POST: one batch of one run's events, a non-empty JSON array. A request is refused in
this order, and the first refusal that applies is the answer:

| Status | When | Body |
|---|---|---|
| `413` | the body is over 2 MiB, or cannot be read | `{"error":"payload_too_large"}` |
| `415` | the content type is not `application/cloudevents-batch+json` | `{"error":"unsupported_media_type"}` |
| `400` | a header the signature depends on is sent twice | `{"error":"bad_request"}` |
| `401` | any failure of authentication | `{"error":"unauthorized"}` |
| `429` | the key has delivered more than its rate; `Retry-After` says how many seconds to wait | `{"error":"rate_limited"}` |
| `400` | the instance id is absent or outside its pattern | `{"error":"bad_request"}` |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included | `{"error":"unsupported_contract_version","supported":[1]}` |
| `400` | the body is not a batch, is over a limit, or holds `dev.qory.ping` or `dev.qory.run.registered` | `{"error":"invalid_request"}` |
| `410` | retention has pruned the run's events: the delivery is recorded, no event is stored | empty |
| `503` | the batch could not be stored; nothing of it was | `{"error":"unavailable"}` |
| `202` | stored | empty |

To the gateway a `2xx` means accepted, `410` means send nothing more for this run, and anything
else is retried with backoff until the run ends.

- **The envelope is checked, the data is not.** Each event has `id` and `subject` (lower-case
  UUIDs), `type` (beginning `dev.qory.`), `sequence` (ten digits, from `0000000001`),
  `source`, `time` (RFC 3339) and `data` (an object), all of one subject. A batch holds at
  most 1000 events; the gateway cuts one at a hundred. A type this release does not know is
  stored like any other, so a newer Forager's events are kept until a release reads them.
  A run opens with its registration, never with an event: a batch that holds
  `dev.qory.ping` is refused, and so is one that holds `dev.qory.run.registered`, which
  stays in the gateway's own record.
- **Delivery is at least once.** An event already held, by its `id`, is skipped. A delivery
  id the key has delivered before is answered `202` again, or `410` for a run retention has
  pruned, and nothing is stored.
- **Stored first, read later.** The batch is stored in one transaction before the answer.
  The events are projected into the run, its connections and its log after the answer, in
  order of `sequence`, never of arrival.
- **What a run is about.** `about` of `dev.qory.run.started`, its kind, title, subjects
  and details, is read within its bounds and shown in the console: its title is the run's
  title. Without one, the run page says "Run" and the run's short id, the lists the short
  id, and the Overview the run's command line, else its short id. A kind, title or
  details past its bound is dropped, never cut, and a subject past its own is dropped
  alone.
- **The rate** is per access key and per server node: 50 batches a second, 100 at once.
  Every request that passed the `413`, the `415` and the `401` spends one, whatever it is
  answered after that. A run's registration and its reloads spend a bucket of their own,
  the same 50 a second and 100 at once, so a gateway flushing a backlog on the same key
  still opens a new run.
- **The digests.** Every `202` and `410` carries `X-Qory-Configuration`. A gateway that
  holds another digest fetches the document again; nothing in an answer's body is read.
  <!-- feature: security -->
  For a workspace with a policy the answer carries `X-Qory-Run-Configuration` too, the
  digest in force for the repository the run's registration named. A gateway that holds
  another digest reloads the run's configuration. That is how a change of the policy,
  the workspace's first among them, reaches a run in flight, and the whole of it.
  <!-- /feature -->
- Neither the signature nor the body is logged, and no batch is answered `500`.

### Enrolment: `POST /.well-known/qory-enrolment`

How a machine enrols a new access key with an enrolment code made on a node
([Nodes and their keys](nodes.md)). `qory access-key enrol <server> <code>` sends it. The
request carries no access key id and no request signature: the code and the proof
authenticate it. Its body, by the contract's `enrolment.schema.json`, holds the code, a
name for the key, the new public key, a timestamp and `proof`, the new key's signature over
the code, the public key, the name and the timestamp.

The code is `qec_`, 26 characters, then `.` and the fingerprint of the server's key, so
the machine knows which key's answer to trust before it has pinned any. It works once, for
15 minutes. Nothing is signed until the code is accepted, the key passes the key checks and
the proof verifies under it. The answers, in order:

| Status | Signed | When |
|---|---|---|
| `413` | no | a body over 8 KiB |
| `415` `unsupported_media_type` | no | no `Content-Type`, or one other than `application/json` |
| `400` `bad_request` | no | `Content-Type` or `X-Qory-Contract-Version` sent twice |
| `429` `rate_limited` | no | over the limit of the address the request came from, with `Retry-After` |
| `400` `unsupported_contract_version` | no | `X-Qory-Contract-Version` absent or not `1` |
| `400` `invalid_request` | no | a body the schema refuses, naming the members at fault |
| `401` `unauthorized` | no | the code is used, expired, cancelled or unknown, carries another fingerprint than the server's key's, or was made by someone who is no longer an owner or an admin of its workspace; or the timestamp is more than 300 seconds from the server's clock |
| `409` `key_invalid` | no | the key fails the key checks, checked first, or the proof does not verify under it |
| `429` `rate_limited` | yes | over the code's own limit, with `Retry-After` |
| `409` `key_invalid` | yes | the key has served another access key, a revoked one included |
| `409` `key_limit` | yes | the node holds two keys |
| `201` | yes | the key is made, and active |

The `201` carries, among its members, the access key id, the node's id and kind and
`apiary_public_key`; each signed refusal lists `apiary_public_key` too, and an unsigned one
none.
<!-- feature: secrets -->
The `201` also carries `stored_secrets`.
<!-- /feature -->
A signed answer is signed under `qory-enrol-answer-ed25519-v1`, and its line 3 is
the request's `proof`. A refusal changes nothing, and the code stays outstanding. The same
code, posted again with the same public key while its 15 minutes last and the key is not
revoked, is the same `201` for the same key; any other key on a used code is `401`.

## A receiver of your own

Forager's repository ships a reference receiver and the fixtures any receiver is tested
against. Discovery, the run endpoint and the events endpoint are enough.
<!-- feature: security -->
A receiver whose run endpoint answers every registration `{"version":1}` offers no run
configuration, and the policy stays the machine's.
<!-- /feature -->
On the machine it is configured like Qory Apiary ([The Forager file's `server`
section](forager-file.md)).
