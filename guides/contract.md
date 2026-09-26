# The server contract

The server contract is what a runner and a server say to each other: how a runner finds the
server's endpoints, how it proves which access key it holds, and how it delivers a run's
events.
<!-- feature: security -->
It is also how a run is given its security policy.
<!-- /feature -->
Qory Apiary implements the server's side. A receiver of your own that implements the same
contract takes the same runners.

## Where the contract lives

The contract is not in this repository. It is the `contracts/runner/v1` directory of the
runner's repository: a README that defines every document and header, one JSON schema per
document, and fixtures, among them signed requests with the status a receiver has to answer.
This server implements version 1, revision 1, tool invocations included: the `tools` of
`dev.qory.run.policy_applied`, and the `tool`, `request_id` and `status` of
`dev.qory.run.egress`.
<!-- feature: security -->
[Tool invocations](security-policy.md#tool-invocations) says what they are.
<!-- /feature -->

Where this page and the contract disagree, the contract wins. Two files in the server's
repository tie the two together:

- `.runner-contract-ref` pins the ref of the runner's repository whose fixtures the server's
  tests replay, in development and in CI: every signed request, the batches, and a recorded
  run in any order, batching and repetition.
- `docs/contract-assumptions.md` is the server's full reading of the contract, with
  everything the contract has not fixed and the server chose, under "Assumed". This page is
  a summary of it.

<!-- feature: security -->
The contract's schemas for the run configuration and the policy are vendored in the server,
and every run configuration is validated against them before it is stored.
<!-- /feature -->

## Who is asking: the access key

Every request names an access key and is signed with that key's secret. The key decides
the workspace: a run is stored in the workspace of the key that delivered it.
<!-- feature: security -->
A run configuration is the one of the key's workspace.
<!-- /feature -->
After a rotation either of a key's two secrets verifies, until the previous one is retired
or the key is revoked.

On every request:

| Header | Value |
|---|---|
| `X-Qory-Access-Key` | the key id, `ak_` and 16 lower-case Crockford base32 characters |
| `X-Qory-Contract-Version` | the revision the runner implements, `1` |
| `User-Agent` | `qory-runner/<version>` |

The server serves revision 1 of contract v1 and nothing else. On every endpoint, a request
that verifies but whose `X-Qory-Contract-Version` is not `1`, absent or sent twice included,
is answered `400` with `{"error":"unsupported_contract_version","supported":[1]}`, and
nothing is served. A request that does not verify is `401` whatever the header says.

The server records the runner's version and the contract version on the key, which is what
the **Runner** column of the access keys page shows. The runner's version never decides the
answer.

## Signed requests

### A signed GET

For the configuration document.
<!-- feature: security -->
The run configuration is fetched the same way.
<!-- /feature -->

| Header | Value |
|---|---|
| `X-Qory-Timestamp` | Unix seconds, UTC, a decimal integer |
| `X-Qory-Signature-256` | `sha256=` and the lower-case hex HMAC SHA-256 of the canonical string, keyed with the secret |

The canonical string is three lines joined by a line feed, with none after the last:

```text
GET
/.well-known/qory-configuration?x=1
1700000000
```

1. the method, in upper case;
2. the request target exactly as sent: the path, then `?` and the query only when the query
   is not empty. Nothing is decoded, re-ordered or normalised on either side;
3. the value of `X-Qory-Timestamp` as sent.

A known answer: the secret `test-secret` over the string above gives
`sha256=e8cc6260e2740e9282f2b45fa8bc590e3afe0e59eb53882b19cdb0f87a613c02`.

**The five-minute window.** The server accepts the request when its own clock and the
timestamp differ by at most 300 seconds, earlier or later alike. A machine whose clock is
more than five minutes wrong is refused, so keep the clocks of the server and of the
machines synchronised.

### A signed POST

For the events endpoint.

| Header | Value |
|---|---|
| `Content-Type` | `application/cloudevents-batch+json` |
| `X-Qory-Delivery` | a UUID per batch; a retry of the batch carries the same one |
| `X-Qory-Signature-256` | `sha256=` and the lower-case hex HMAC SHA-256 of the raw request body, keyed with the secret |
<!-- feature: security -->
| `X-Qory-Run-Configuration` | optional: the digest of the run configuration the run holds |
<!-- /feature -->

No timestamp is signed and no window is checked: a replayed batch is a duplicate, and the
server discards duplicates by event id. The signature is verified over the bytes as
received, before anything parses them.

### Failure

Every failure of authentication is `401` with the body `{"error":"unauthorized"}` and
nothing more: a header missing, empty or sent twice, a key id of the wrong shape, a key the
server does not know or has revoked, a timestamp that is not an integer or is outside the
window, a signature that does not match. The body never says which, and nothing about the
request's headers is logged. The comparison is constant-time, and the key is looked up only
after its shape is checked.

## The endpoints

### Discovery: `GET /.well-known/qory-configuration`

A signed GET. The answer is `200`, `application/json`, with the header
`X-Qory-Configuration: sha256=<hex>`, the SHA-256 of the body as sent. A contract version
other than `1` is `400 unsupported_contract_version`, as on every endpoint.

```json
{
  "version": 1,
  "events": {"url": "https://qory.example/v1/events", "types": ["*"]}
}
```

The URLs are built from the server's `PUBLIC_URL`, never from the request's `Host` header
([Install and configure](install.md)). A runner's `server.url` is that address, and the
runner finds the other endpoints through this document alone.

<!-- feature: security -->
For a workspace whose policy somebody has made, the document has a `run` section too,
`"run": {"url": "https://qory.example/v1/run-configuration"}`. A workspace nobody has
given a policy is answered the document without `run`, and its machines run under the
policy of their own runner file ([The security policy](security-policy.md)). The document
is therefore one of two, by workspace, and so is its digest.
<!-- /feature -->

### Events: `POST /v1/events`

A signed POST: one batch of one run's events, a non-empty JSON array. A request is refused in
this order, and the first refusal that applies is the answer:

| Status | When | Body |
|---|---|---|
| `413` | the body is over 2 MiB, or cannot be read | `{"error":"payload_too_large"}` |
| `401` | any failure of authentication | `{"error":"unauthorized"}` |
| `415` | the content type is not `application/cloudevents-batch+json` | `{"error":"unsupported_media_type"}` |
| `429` | the key has delivered more than its rate; `Retry-After` says how many seconds to wait | `{"error":"rate_limited"}` |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included | `{"error":"unsupported_contract_version","supported":[1]}` |
| `400` | the body is not a batch, or is over a limit | `{"error":"invalid_batch"}` |
| `410` | the workspace has closed the run: the delivery is recorded, no event is stored | empty |
| `503` | the batch could not be stored; nothing of it was | `{"error":"unavailable"}` |
| `202` | stored | empty |

To a runner a `2xx` means accepted, `410` means send nothing more for this run, and anything
else is retried with backoff until the run ends. The ping that opens a run is a batch like
any other: a `202` lets the run start, and a revoked key, a bad signature or an unsupported
version does not.

- **The envelope is checked, the data is not.** Each event has `id` and `subject` (lower-case
  UUIDs), `type` (beginning `dev.qory.`), `sequence` (ten digits, from `0000000001`),
  `source`, `time` (RFC 3339) and `data` (an object), all of one subject. A batch holds at
  most 1000 events; a runner cuts one at a hundred. A type this release does not know is
  stored like any other, so a newer runner's events are kept until a release reads them.
- **Delivery is at least once.** An event already held, by its `id`, is skipped. A delivery
  id the key has delivered before is answered `202` again and nothing is stored.
- **Stored first, read later.** The batch is stored in one transaction before the answer.
  The run is created on the first event of a subject the key's workspace has not seen. The
  events are projected into the run, its connections and its log after the answer, in
  order of `sequence`, never of arrival.
- **The rate** is per access key and per node: 50 batches a second, 100 at once. Every
  request that passed the `413`, the `401` and the `415` spends one, whatever it is answered
  after that.
- **The digests.** Every `202` and `410` carries `X-Qory-Configuration`. A runner that
  holds another digest fetches the document again; nothing in an answer's body is read.
  <!-- feature: security -->
  For a workspace with a policy the answer carries `X-Qory-Run-Configuration` too, the
  digest in force for the run's repository. That is how a change of the policy reaches a
  run in flight, and the whole of it.
  <!-- /feature -->
- Neither the signature nor the body is logged, and no batch is answered `500`.

<!-- feature: security -->
### The run configuration: `GET /v1/run-configuration`

A signed GET, with the query signed as sent: one parameter per label of the run. The
runner sends every label of the run, such as
`?forge=github.com&issue=77&repository=acme%2Fshop`. The
server reads every parameter as a label and reads the repository from two of them, `forge`
and `repository` (`Apiary.Lingo.Domain.Software`). Any other label names nothing. A
repository the workspace does not know, or labels that name none, get the workspace's
baseline.

| Status | When | Body |
|---|---|---|
| `200` | the workspace has a policy | the run configuration |
| `400` | `X-Qory-Contract-Version` is not `1`, absent or sent twice included | `{"error":"unsupported_contract_version","supported":[1]}` |
| `401` | any failure of authentication | `{"error":"unauthorized"}` |
| `404` | nobody has made the workspace's policy; discovery named no `run` section, so a runner does not ask | `{"error":"not_found"}` |
| `429` | the key's rate, the events endpoint's bucket, is spent; with `Retry-After` | `{"error":"rate_limited"}` |
| `503` | the configuration could not be read | `{"error":"unavailable"}` |

To a runner anything but `200` is no run, or a reload that failed and is tried again on the
next answer. The endpoint never answers `304`.

A `200` carries `X-Qory-Run-Configuration: sha256=<hex>`, `ETag` with the same string
quoted, `X-Qory-Configuration` and `Cache-Control: no-store`:

```json
{"version":1,"security_policy":{"version":1,"egress":{"mode":"enforce","allow":["api.example"]}}}
```

The body is the bytes that were stored when the policy was last changed. Nothing is
rendered for a request, so the digest is of exactly what is sent. It is the configuration
of the key's workspace for the repository the two labels name; a repository the workspace
has not seen, one with no rules of its own, and a request that names none, or one label of
the two, get the workspace's baseline. The labels are compared to the stored ones byte for
byte after the query's percent-decoding. The server does not answer `400` to a query the
contract's rules for labels refuse, as the reference receiver does: a `forge` or
`repository` that cannot be a label names no repository, and of a parameter sent twice the
last is read.

The `security_policy` is the policy: the runner does not merge it with the machine's own.
When the policy has deny rules its `egress` carries `deny` after `allow`, the hosts the
runner denies first and in either mode; without any, the section is as above.
<!-- /feature -->

## A receiver of your own

The runner's repository ships a reference receiver and the fixtures any receiver is tested
against. Discovery and the events endpoint are enough.
<!-- feature: security -->
A receiver that names no `run` section offers no run configuration, and the policy stays
the machine's.
<!-- /feature -->
On the machine it is configured like Qory Apiary ([The runner file's `server`
section](runner-file.md)).
