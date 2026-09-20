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
  "events": {"url": "https://<public host>/v1/events", "types": ["*"]}
}
```

`<public host>` is the application's public base URL (`PUBLIC_URL`). The `events` URL is
the events endpoint below. The `run`
section is deliberately absent until the run configuration exists: a runner refuses to run
when a section the document names does not answer, and runs under its machine's own policy
when the section is absent. Sections a runner does not know are to be ignored.

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
| `400` | `X-Qory-Contract-Version` is sent and is not `1` | `{"error":"unsupported_contract_version","supported":[1]}` |
| `400` | the body is not a batch | `{"error":"invalid_batch"}` |
| `410` | the hive has closed the run: the delivery is recorded, no event is stored | empty |
| `202` | stored | empty |

Every `202` and `410` carries `X-Qory-Configuration`, the same digest the discovery answer
carries. `X-Qory-Run-Configuration` is not answered until the run configuration exists. No
error body repeats anything that was sent. The ping is a batch like any other: a `2xx` lets the
run start, and a revoked key, a bad signature or an unsupported version does not.

A batch is a non-empty JSON array of objects, each with `id` and `subject` (lowercase UUIDs),
`type` (beginning `ai.qory.`), `sequence` (ten digits), `source` (`urn:qory:run:` and the
subject), `time` (RFC 3339) and `data` (an object), all of one subject. Only this envelope is
checked: `data` is not validated against the schema of its type, and a type this release does
not know is stored like any other, so a newer runner's events are kept until a release reads
them.

What is stored, in one transaction, before the answer:

- the run, created on the first event of a subject the key's hive has not seen, in that hive,
  in state `pending`, with the key that delivered it and the versions the request named. The
  same subject under another hive is another run. Two first batches at once make one run;
- each event, as received: `id`, `sequence` as an integer, `type`, `time`, `data`, and when it
  was received. An event already held (the same `id`) is skipped: delivery is at least once.
  An event whose `id` is held by another run of the hive, or whose `sequence` in its run is
  held under another `id`, is dropped and counted in a log line; it is never an error, since
  sending it again could not help. Events are read back by `sequence`, never by arrival;
- the delivery: the key, `X-Qory-Delivery`, the subject, how many events it held, how many were
  new, the status answered. A delivery id the key has delivered before is answered `202` again
  and nothing is stored;
- on the run: the count of events, when the last one was received, and the last
  `X-Qory-Run-Configuration` that had the shape `sha256=` and 64 lowercase hex digits.

After the commit, and never failing the request: the key records the time, the runner version
and the contract version, and the time of the batch's last heartbeat when it holds one; the
run's events are projected into the run, its connections and its log, on the server's own
time. Nothing of a request's headers beyond the above is stored, and neither the signature nor
the body is logged.

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
  (`config :apiary, Apiary.Runs.RateLimit, rate: 50, burst: 100`). A refused request of any
  other kind spends nothing of it.
- Events are stored as received and unknown types are kept. The one exception: a NUL
  character inside `data`, which Postgres cannot hold, is stored as U+FFFD; a `type` with one
  is not a batch.
- `time` may carry any RFC 3339 offset and is stored in UTC, to the microsecond.
- `X-Qory-Delivery` that is absent or not a UUID does not fail the delivery: the batch is
  stored and its delivery is recorded under an id the server makes up, so such a delivery is
  deduplicated by event id only.
- `X-Qory-Timestamp`, `X-Qory-Access-Key` or `X-Qory-Signature-256` sent twice on a POST is
  `401`, though the timestamp's value is not read.
- A `POST` answers `503 {"error":"unavailable"}` when the batch cannot be stored; a runner
  retries anything that is not `2xx` or `410`.
